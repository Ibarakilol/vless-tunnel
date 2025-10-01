#!/bin/bash

# конфиг и лог файл
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/settings.conf"
LOG_FILE="/tmp/vless-tunnel.log"
SUBSCRIPTION_FILE="tunnel.txt"
WSPATH="/"

# логи
log() {
	echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
	echo "$1"
}

# установка компонентов
install_dependencies() {
	echo "Установка зависимостей..."

	apt update # && apt upgrade -y
	apt-get install curl cron unzip -y

	# скачивание и установка AWS CLI v2
	curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
	unzip awscliv2.zip
	./aws/install
	rm -rf awscliv2.zip aws/
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
#profile-title: base64:dmxlc3MtdHVubmVs
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
		echo "Файл подписки успешно загружен: $file_url"
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
	local response=$(curl -sk \
			--connect-timeout 5 \
			--max-time 8 \
			--retry 2 \
			--retry-delay 1 \
			--retry-max-time 10 \
			"$url" 2>/dev/null)
	local exit_code=$?

	if [[ $exit_code -ne 0 ]]; then
		log "Ошибка проверки туннеля (curl exit code: $exit_code)"
		return 1
	fi

	if echo "$response" | grep -q "Bad Request"; then
		log "Туннель работает нормально ($domain)"
		return 0
	else
		if echo "$response" | grep -q "there is no tunnel connection associated with given host"; then
			log "Туннель не ассоциирован с доменом."
		else
			log "Проблема с туннелем ($domain). Неверный ответ. Ответ: $response"
		fi

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

	# получаем все PID процессов vk-tunnel с указанным портом
	local pids=($(pgrep -f "vk-tunnel --port=$INBOUNDPORT"))

	# если найдены процессы, убиваем их все
	if [[ ${#pids[@]} -gt 0 ]]; then
		echo "Найдено процессов vk-tunnel: ${#pids[@]}"
		echo "PID процессов: ${pids[*]}"

		for pid in "${pids[@]}"; do
			echo "Убиваем процесс vk-tunnel с PID: $pid"
			kill -9 "$pid" 2>/dev/null
		done

		# дополнительная проверка и принудительное убийство через pkill
		pkill -f "vk-tunnel --port=$INBOUNDPORT" 2>/dev/null

		sleep 2

		# проверяем, что все процессы убиты
		local remaining_pids=($(pgrep -f "vk-tunnel --port=$INBOUNDPORT"))

		if [[ ${#remaining_pids[@]} -gt 0 ]]; then
			echo "Предупреждение: остались процессы после убийства: ${remaining_pids[*]}"
		else
			echo "Все процессы vk-tunnel успешно убиты"
		fi
	else
		echo "Активных процессов vk-tunnel не найдено"
	fi

	log "Запуск vk-tunnel на порту $INBOUNDPORT..."

	# запускаем новый процесс
	vk-tunnel --port="$INBOUNDPORT" > "$LOG_FILE" 2>&1 &

	# цикл проверки домена
	log "Ожидание появления домена в логах..."
	local domain

	for ((i=1; i<=30; i++)); do
		sleep 1
		domain=$(get_current_domain)

		if [[ -n "$domain" ]]; then
			log "Домен найден: $domain (попытка $i/30)"
			break
		fi

		log "Домен еще не появился в логах... (попытка $i/30)"
	done

	if [[ -z "$domain" ]]; then
		log "Ошибка: домен не найден в логах после 30 секунд ожидания"
		return 1
	fi

	local vk_pid=$(pgrep -f "vk-tunnel --port=$INBOUNDPORT")

	if [[ -z "$vk_pid" ]]; then
		log "Ошибка: vk-tunnel не запустился"
		return 1
	fi

	log "vk-tunnel запущен (PID: $vk_pid)"

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
	# install_dependencies

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
	local file_url
	file_url=$(upload_to_yandex_cloud "$domain")

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

	echo "Установка завершена. Логи: tail -f $LOG_FILE"

	# отображение URL подписки после установки
	echo "$file_url"
}

# надзорный скрипт watchdog
watchdog() {
	log "Запуск watchdog-проверки"

	if ! read_config; then
		log "Ошибка: не удалось прочитать конфигурацию"
		exit 1
	fi

	# чекаем туннель
	if check_tunnel "$LAST_DOMAIN"; then
		log "Ничего не делаем, всё хорошо"
		exit 0
	fi

	log "Обнаружена проблема с туннелем. Перезапуск..."

	# рестарт туннеля
	if ! start_vk_tunnel; then
		exit 1
	fi

	# смотрим на то, какой домен выдал вк
	local new_domain=$(get_current_domain)

	if [[ -z "$new_domain" ]]; then
		log "Ошибка: не удалось получить новый домен"
		exit 1
	fi

	log "Новый домен: $new_domain"

	# если домен изменился, обновляем файл конфиг
	if [[ "$new_domain" != "$LAST_DOMAIN" ]]; then
		log "Домен изменился. Обновление файла подписки..."

		if upload_to_yandex_cloud "$new_domain"; then
			LAST_DOMAIN="$new_domain"
			write_config

			log "Файл подписки успешно обновлен"
		fi
	else
		log "Домен не изменился"
	fi

	log "Watchdog проверка завершена"
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
