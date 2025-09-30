#!/bin/bash

# конфиг и лог файл
CONFIG_FILE="$(dirname "$0")/settings.conf"
LOG_FILE="/tmp/vk-tunnel.log"

# установка компонентов
install_dependencies() {
	echo "Установка зависимостей..."

	apt update # && apt upgrade -y
	apt-get install qrencode bash curl cron -y
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
WSPATH="$WSPATH"
LAST_DOMAIN="$LAST_DOMAIN"
EOF

	chmod 600 "$CONFIG_FILE"
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

get_vless_link() {
	local domain="$1"
	local encoded_wspath=$(urlencode "$WSPATH")
	local vless_link="vless://${UUID}@${domain}:443/?type=ws&path=${encoded_wspath}&security=tls#vk-tunnel"

	echo ""
	echo "=== Vless-ссылка ==="
	echo "$vless_link"
	echo ""
	echo "=== QR код ==="
	qrencode -t UTF8 "$vless_link"
	echo ""
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

	echo "Введите путь инбаунда (по умолчанию: /):"
	read -r WSPATH
	WSPATH="${WSPATH:-"/"}"
	echo

	# установка зависимостей
	install_dependencies

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

	# добавляем в cron
	# echo "Добавление в cron: $script_path"
	# (crontab -l 2>/dev/null | grep -v "$script_path"; echo "* * * * * /bin/bash '$script_path' --watch") | crontab -
	# echo "Задача добавлена в cron"

	echo "Установка завершена. Логи: $LOG_FILE"
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
		echo "Домен изменился"

		LAST_DOMAIN="$new_domain"
		write_config
		echo "Конфигурационный файл успешно обновлен"
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
