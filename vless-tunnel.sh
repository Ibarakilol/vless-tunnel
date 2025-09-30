#!/bin/bash

# конфиг и лог файл
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/settings.conf"
LOG_FILE="/tmp/vk-tunnel.log"
SUBSCRIPTION_FILE="tunnel.txt"
WSPATH="/"

# установка компонентов
install_dependencies() {
	echo "Установка зависимостей..."

	apt update # && apt upgrade -y
	apt-get install curl cron unzip -y

	# скачивание и установка AWS CLI v2
	curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
	unzip awscliv2.zip
	./aws/install && rm -rf awscliv2.zip aws/
}

# настройка awscli для s3 яндекса
configure_aws() {
	echo "Настройка AWS CLI для Yandex.Cloud..."
	mkdir -p ~/.aws

	cat > ~/.aws/config << EOF
[default]
region=ru-central1
output=json
EOF

	cat > ~/.aws/credentials << EOF
[default]
aws_access_key_id=$SA_ACCESS_KEY_ID
aws_secret_access_key=$SA_SECRET_ACCESS_KEY
EOF

	chmod 600 ~/.aws/credentials
}

# читаем конфиг
read_config() {
	if [[ -f "$CONFIG_FILE" ]]; then
		source "$CONFIG_FILE"
	else
		echo "Конфигурационный файл не найден: $CONFIG_FILE"
		return 1
	fi
}

# пишем конфиг
write_config() {
	cat > "$CONFIG_FILE" << EOF
UUID="$UUID"
INBOUNDPORT="$INBOUNDPORT"
BUCKET_NAME="$BUCKET_NAME"
SA_ACCESS_KEY_ID="$SA_ACCESS_KEY_ID"
SA_SECRET_ACCESS_KEY="$SA_SECRET_ACCESS_KEY"
LAST_DOMAIN="$LAST_DOMAIN"
EOF

	chmod 600 "$CONFIG_FILE"
}

# создаём txt-файл подписки
create_subscription_file() {
	local domain="$1"
	local encoded_wspath=$(urlencode "$WSPATH")
	local vless_link="vless://${UUID}@${domain}:443?type=ws&path=${encoded_wspath}&security=tls#${domain}"

	cat > "/tmp/$SUBSCRIPTION_FILE" << EOF
#profile-update-interval: 1
#profile-title: base64:ZWFzeS12ay10dW5uZWw=
$vless_link
EOF

	echo "Файл подписки создан: /tmp/$SUBSCRIPTION_FILE"
}

# загружаем подписку в s3 яндекса
upload_to_yandex_cloud() {
	local domain="$1"

	create_subscription_file "$domain"

	echo "Загрузка файла подписки в бакет $BUCKET_NAME..."

	if aws --endpoint-url=https://storage.yandexcloud.net s3 cp "/tmp/$SUBSCRIPTION_FILE" "s3://$BUCKET_NAME/" --cache-control "no-store" > /dev/null 2>&1; then
		local file_url="https://storage.yandexcloud.net/$BUCKET_NAME/$SUBSCRIPTION_FILE"
	else
		echo "Ошибка загрузки файла в бакет"
		return 1
	fi
}

# функция для URL encoding
urlencode() {
	local string="$1"
	local length="${#string}"
	local encoded=""
	local i char

	for ((i = 0; i < length; i++)); do
		char="${string:i:1}"
		case "$char" in
			[a-zA-Z0-9.~_-]) encoded+="$char" ;;
			*) encoded+=$(printf '%%%02X' "'$char") ;;
		esac
	done

	echo "$encoded"
}

# чекер работоспособности туннеля
check_tunnel() {
	local domain="$1"
	local url="https://${domain}${WSPATH}"
	local response=$(curl -sk --max-time 10 "$url" 2>/dev/null)
	local exit_code=$?

	if [[ $exit_code -ne 0 ]]; then
		echo "Ошибка проверки туннеля (curl exit code: $exit_code)"
		return 1
	fi

	if echo "$response" | grep -q "Bad Request"; then
		echo "Туннель работает нормально ($domain)"
		return 0
	else
		echo "Проблема с туннелем ($domain). Ответ: $response"
		return 1
	fi
}

# получаем домен туннеля из вывода после запуска
get_current_domain() {
	local domain

	# Извлекаем домен из логов
	domain=$(grep -oE 'https://[a-zA-Z0-9-]+[-a-zA-Z0-9]*\.tunnel\.vk-apps\.com' "$LOG_FILE" 2>/dev/null | tail -n 5 | sed 's|https://||')

	if [[ -z "$domain" ]]; then
		domain=$(grep -oE 'wss://[a-zA-Z0-9-]+[-a-zA-Z0-9]*\.tunnel\.vk-apps\.com' "$LOG_FILE" 2>/dev/null | tail -n 5 | sed 's|wss://||')
	fi

	echo "$domain"
}

# запускаем туннель
start_vk_tunnel() {
	# проверяем, установлен ли vk-tunnel
	if ! command -v vk-tunnel &> /dev/null; then
		echo "Ошибка: vk-tunnel не установлен или не найден в PATH"
		exit 1
	fi

	echo "Запуск vk-tunnel на порту $INBOUNDPORT..."

	pkill -f "vk-tunnel --port=$INBOUNDPORT"
	sleep 2

	vk-tunnel --port="$INBOUNDPORT" > "$LOG_FILE" 2>&1 &

	# цикл проверки домена
	echo "Ожидание появления домена в логах..."
	local domain

	for ((i=1; i<=30; i++)); do
		sleep 1
		domain=$(get_current_domain)

		if [[ -n "$domain" ]]; then
			echo "Домен найден: $domain (попытка $i/30)"
			break
		fi

		echo "Домен еще не появился в логах... (попытка $i/30)"
	done

	if [[ -z "$domain" ]]; then
		echo "Ошибка: домен не найден в логах после 30 секунд ожидания"
		return 1
	fi

	local vk_pid=$(pgrep -f "vk-tunnel --port=$INBOUNDPORT")

	if [[ -z "$vk_pid" ]]; then
		echo "Ошибка: vk-tunnel не запустился"
		return 1
	fi

	echo "vk-tunnel запущен (PID: $vk_pid)"

	return 0
}

# процесс установки
install() {
	echo "Начало установки"

	echo "Введите UUID:"
	read -r UUID

	echo "Введите порт инбаунда:"
	read -r INBOUNDPORT

	echo "Введите имя бакета:"
	read -r BUCKET_NAME

	echo "Введите идентификатор статического доступа сервисного аккаунта:"
	read -r SA_ACCESS_KEY_ID

	echo "Введите ключ статического доступа сервисного аккаунта:"
	read -r SA_SECRET_ACCESS_KEY
	echo

	# установка зависимостей
	install_dependencies

	# настройка awscli
	configure_aws

	# сохраняем конфиг
	write_config

	# запускаем vk-tunnel
	if ! start_vk_tunnel; then
		exit 1
	fi

	# получаем домен
	local domain=$(get_current_domain)

	if [[ -z "$domain" ]]; then
		echo "Ошибка: не удалось получить домен vk-tunnel"
		exit 1
	fi

	# обновляем конфиг, вписываем в него последний домен
	LAST_DOMAIN="$domain"
	write_config

	# создаём и загружаем txt подписки в s3 яндекса
	local file_url=$(upload_to_yandex_cloud "$domain")

	if [[ -z "$file_url" ]]; then
		exit 1
	fi

	# добавляем в cron
	local script_path="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

	# Проверяем, существует ли файл скрипта
	if [[ ! -f "$script_path" ]]; then
		echo "Ошибка: скрипт не найден по пути: $script_path"
		return 1
	fi

	echo "Добавление в cron: $script_path"
	(crontab -l 2>/dev/null | grep -v "$script_path"; echo "* * * * * /bin/bash '$script_path' --watch") | crontab -
	echo "Задача добавлена в cron. Посмотреть можно через: crontab -e"

	echo "Установка завершена. Логи: $LOG_FILE"

	echo ""
	echo "================Файл подписки успешно загружен=================="
	echo "$file_url"
	echo "================================================================"
	echo ""
}

# надзорный скрипт watchdog
watchdog() {
	echo "Запуск watchdog-проверки"

	if ! read_config; then
		echo "Ошибка: не удалось прочитать конфигурацию"
		exit 1
	fi

	# чекаем туннель
	if check_tunnel "$LAST_DOMAIN"; then
		echo "Ничего не делаем, всё хорошо"
		exit 0
	fi

	echo "Обнаружена проблема с туннелем. Перезапуск..."

	# рестарт туннеля
	if ! start_vk_tunnel; then
		exit 1
	fi

	# смотрим на то, какой домен выдал вк
	local new_domain=$(get_current_domain)

	if [[ -z "$new_domain" ]]; then
		echo "Ошибка: не удалось получить новый домен"
		exit 1
	fi

	echo "Новый домен: $new_domain"

	# если домен изменился, обновляем файл конфиг
	if [[ "$new_domain" != "$LAST_DOMAIN" ]]; then
		echo "Домен изменился. Обновление файла подписки..."

		if upload_to_yandex_cloud "$new_domain"; then
			LAST_DOMAIN="$new_domain"
			write_config

			echo "Файл подписки успешно обновлен"
		fi
	else
		echo "Домен не изменился"
	fi

	echo "Watchdog проверка завершена"
}

# скрипт запуска туннеля
run_tunnel() {
	if ! read_config; then
		echo "Ошибка: Конфигурационный файл не найден. Запуск начальной настройки..."
		install
	else
		start_vk_tunnel
	fi
}

# логика
case "${1:-}" in
	"--watch")
		watchdog
		;;
	"--run")
		run_tunnel
		;;
	*)
		echo "Использование: $0 [OPTION]"
		echo ""
		echo "Опции:"
		echo "  --watch       Запуск надзорного скрипта watchdog (для cron)"
		echo "  --run            Запуск туннеля с конфигурацией"
		echo ""
		echo "Пример: $0 --run"
		;;
esac
