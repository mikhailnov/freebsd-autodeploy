#!/bin/sh
##!/usr/local/bin/bash
# This script must be POSIX compatible, otherwise it will not run with /bin/sh on FreeBSD!
# I use spellchek in Geany GUI (Build-->Lint) to check it while coding

echo_err(){
	echo "$@" 1>&2
}

read_p(){
	# read -p is not compatible with POSIX shell
	echo -n "$@"
	read -r answer
	echo "$answer" >/dev/null
}
echo_help(){
	echo "
Запустите скрипт с одним из параметров:
	./freebsd-autodeploy.sh 3proxy-setup
		3proxy-setup выполнит установку и настройку 3proxy с нуля на вашей системе, в т.ч. настроит FreeBSD (локаль, обновит систему и т.д.), а потом выполнит добавления пользователя (adduser)
	./freebsd-autodeploy.sh listusers
		listusers выведет список пользователей прокси-сервера с паролями
	./freebsd-autodeploy.sh serverinfo
		serverinfo попробует определить IPv4 и IPv6 адреса вашего прокси-сервера и выведет порты прокси-сервера
	./freebsd-autodeploy.sh adduser
		adduser запросит имя пользователя и пароль, добавит этого пользователя в 3proxy и перезапустит прокси-сервер
	./freebsd-autodeploy.sh deluser
		adduser запросит имя пользователя и удалит указанного пользователя
	./freebsd-autodeploy.sh setup-freebsd
		Выполнит базовую настройку ОС FreeBSD: настроит русскую локаль, обновит систему
	"
}
uname_os="$(uname --)"
	case "$uname_os" in
		"FreeBSD")
			echo "Работаем на FreeBSD"
			CONFIG_DIR="/usr/local/etc/"
		;;
		"Linux")
			echo_err "Вы запустили этот скрипт на Linux, но пока что скрипт может работать только на FreeBSD! (Пулл-реквесты https://github.com/mikhailnov/./freebsd-autodeploy.sh для поддержки других ОС принимаются)"
			exit 1
		;;
		*)
			echo_err "Вы запустили скрипт на неизвестной ОС, пока поддерживается только FreeBSD! (Пулл-реквесты https://github.com/mikhailnov/./freebsd-autodeploy.sh для поддержки других ОС принимаются)"
			exit 1
		;;
	esac

	if [ "$(id -u)" != "0" ]; then
		echo_err "Скрипт нужно запустить от root!"
		# продублируем ошибку на английском, т.к. при отсусттвии локали UTF-8 русские буквы не пропечатаются
		echo_err "Run this script as root!"
		exit 1
	fi

freebsd_initial_setup(){
	# this initial setup is not needed in FreeBSD default images on DigitalOcean hosting, but is needed on clean installations from official FreeBSD ISOs
	# this function must work in POSIX shell, because bash is not installed by default
	# pkg is not installed by default
	# without env it will not work in csh
	env ASSUME_ALWAYS_YES=yes pkg install pkg
	pkg update
	pkg upgrade -y
	#freebsd-update -F fetch install
	if ! cat /etc/login.conf | grep -v ^# | grep -Fq "UTF-8"; then
		mv -v /etc/login.conf /etc/login.conf.bak
		# I took /etc/login.conf from DigitalOcean'f FreeBSD image
		cat > /etc/login.conf <<-EOF
		default:lang=en_US.UTF-8:\
		:passwd_format=sha512:\
		:copyright=/etc/COPYRIGHT:\
		:welcome=/etc/motd:\
		:setenv=MAIL=/var/mail/$,BLOCKSIZE=K:\
		:path=/sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin ~/bin:\
		:nologin=/var/run/nologin:\
		:cputime=unlimited:\
		:datasize=unlimited:\
		:stacksize=unlimited:\
		:memorylocked=64K:\
		:memoryuse=unlimited:\
		:filesize=unlimited:\
		:coredumpsize=unlimited:\
		:openfiles=unlimited:\
		:maxproc=unlimited:\
		:sbsize=unlimited:\
		:vmemoryuse=unlimited:\
		:swapuse=unlimited:\
		:pseudoterminals=unlimited:\
		:kqueues=unlimited:\
		:umtxp=unlimited:\
		:priority=0:\
		:ignoretime@:\
		:umask=022:

		standard:\
			:tc=default:
		xuser:\
			:tc=default:
		staff:\
			:tc=default:
		daemon:\
			:memorylocked=128M:\
			:tc=default:
		news:\
			:tc=default:
		dialer:\
			:tc=default:

		root:\
			:ignorenologin:\
			:memorylocked=unlimited:\
			:tc=default:

		russian|Russian Users Accounts:\
			:charset=UTF-8:\
			:lang=ru_RU.UTF-8:\
			:tc=default:

		EOF
		cap_mkdb /etc/login.conf
		echo "Please relogin and run this script again! Otherwise Russian language will not work in the console!" && exit
	fi
}

proxy_setup(){
	
	if which pkg >/dev/null
		then
			echo "Пакетный менеджер бинарных пакетов pkg найден, продолжаем работать."
		else
			echo_err "Пакетный менеджер бинарных пакетов pkg не найден, не можем продолжить работу."
			exit 1
	fi

	if grep -Fq "proxy\:" /etc/passwd
		then
			echo "Пользователь proxy найден, не будем его создавать"
		else
			echo "Пользователь proxy не найден, создадим его"
			#echo "proxy:*:62:62:Packet Filter pseudo-user:/nonexistent:/usr/sbin/nologin" >>/etc/passwd
			#pw adduser proxy1 -g proxy1 -d /nonexistent -s /usr/sbin/nologin -c "Packet Filter pseudo-user"
			if awk -F":" '{print $3}' /etc/passwd | grep -Fq ^62$
				then 
					C_UID="62"
				else
					LAST_UID="$(awk -F":" '{print $3}' /etc/passwd | sort --sort=general-numeric | tail -n 1)"
					C_UID=$((LAST_UID+1))
					echo "Пользователь с UID 62 уже занят, попробуем UID ${C_UID}"
			fi
			
			if awk -F":" '{print $3}' /etc/group | grep -Fq "^62$"
				then 
					C_GID="62"
				else
					LAST_GID="$(awk -F":" '{print $3}' /etc/passwd | sort --sort=general-numeric | tail -n 1)"
					C_GID=$((LAST_GID+1))
					echo "Группа с GID 62 уже занята, попробуем GID ${C_GID}"
			fi
			
			if pw addgroup -n proxy -g "$C_GID"
				then
					echo ""
				else
					echo_err "Не получилось создать группу с GID ${C_GID}, не сможем продолжить работать!"
					exit 1
			fi
			
			if pw adduser proxy -g proxy -u "$C_UID" -d /nonexistent -s /usr/sbin/nologin -c "Packet Filter pseudo-user"
				then
					echo ""
				else
					echo_err "Не получилось создать пользователя с UID ${C_UID}, не сможем продолжить работать!"
					exit 1
			fi
			
	fi

	# coreutils нужен для утилиты gshuf для генерации случайных номеров портов
	if pkg install -y 3proxy coreutils curl
		then
			echo "3proxy + coreutils + curl успешно установлены"
		else
			echo_err "Ошибка установки 3proxy и/или coreutils, curl из бинарного репозитория, не можем продолжить работу!"
			exit 1
	fi

	if echo "threeproxy_enable=\"YES\" " >>/etc/rc.conf
		then
			echo "Сервис 3proxy добавлен в автозапуск"
		else
			echo_err "Ошибка добавления сервиса 3proxy в автозапуск"
	fi

	if cd "$CONFIG_DIR"
		then
			echo ""
		else
			echo_err "Ошибка перехода в директорию с конфигами 3proxy; такого не должно быть, возможно, ваша ОС поломана, или у вас не используется директория $CONFIG_DIR для конфигов и вам стоит настроить 3proxy вручную, а не автоматически этим скриптом; не можем продолжить работать!"
			exit 1
	fi

	if mv -v 3proxy.cfg 3proxy.cfg.bak
		then
			echo ""
		else
			echo_err "Ошибка перемещения конфига 3proxy (создания его резервной копии), возможно, пакет 3proxy не установился корректно, не можем продолжить работать!"
			exit 1
	fi

	# alias-ы настраиваем, чтобы в будущем скрипт мог работать и на Linux с shuf, и на FreeBSD с gshuf (на ней нет shuf, т.к. это только GNU-утилита из пакета coreutils)
	if test -f "$(which shuf)"
		then
			alias shuf="$(which shuf)"
		else
			test -f "$(which gshuf)" && alias shuf="$(which gshuf)"
	fi

	if shuf --version >/dev/null
		then
			echo ""
			PORT_HTTP="$(shuf -i30000-70000 -n1)"
		else
			echo_err "Утилита shuf/gshuf не найдена в системе, она должна принадлежать пакету coreutils, который мы уже установили, не можем сгенерировать случайные порты для прокси-сервера"
			# read -p is not compatible with POSIX shell (/bin/sh in FreeBSD)
			read_p "Будут использоваться НЕ СЛУЧАЙНО сгенерированные порты прокси-сервера, а предустановленные, это опасно с точки зрения защиты от взлома! Нажмите Enter, если вы с этим согласны, или Ctrl+C для завершения скрипта!"
			PORT_HTTP=5454
	fi

	PORT_SOCKS="$((PORT_HTTP+1))"

	LOG_DIR="/var/log/3proxy/"
	if ( mkdir -p "$LOG_DIR" && chown -R proxy:proxy "LOG_DIR" )
		then
			echo ""
			logs_string="log $LOG_DIR D"
		else
			echo_err "Не удалось создать папку $LOG_DIR для логов прокси-сервера или поставить на нее правильные права, отключаем ведение логов!"
			logs_string=""
	fi
	cat > 3proxy.cfg <<-EOF
	setgid ${C_GID}
	setuid ${C_UID}
	nserver 8.8.8.8
	nserver 77.88.8.8
	nserver 9.9.9.9
	nserver 77.88.8.1
	nscache 65536
	timeouts 1 5 30 60 180 1800 15 60
	daemon
	${logs_string}
	logformat "- +_L%t.%.  %N.%p %E %U %C:%c %R:%r %O %I %h %T"
	archiver zip zip -m -qq %A %F
	rotate 30
	maxconn 500
	deny * * 127.0.0.1,192.168.1.1
	#allow * * * 80-88,8080-8088 HTTP
	#allow * * * 443,8443 HTTPS

	flush
	auth strong
	# users username:CL:password
	users \$${CONFIG_DIR}3proxy.cfg.auth

	proxy -p${PORT_HTTP}
	socks -p${PORT_SOCKS}
	dnspr 
	EOF
}

print_server_info(){
	# определим глобальный IP-адрес этого сервера
	# манипуляции ниже нужны для определения отдельно IPv4 и IPv6 адресов; поу молчанию FreeBSD/Linux обращаются к IPv6, если он доступен
	#SITE_IPv6="$(host -t AAAA wtfismyip.com | rev | cut -d " " -f1 | rev)"
	#SITE_IPv4="$(host -t A wtfismyip.com | rev | cut -d " " -f1 | rev)"
	MY_IPv4="$(curl -4 -- "http://wtfismyip.com/text" 2>/dev/null )"
	MY_IPv6="$(curl -6 -- "http://wtfismyip.com/text" 2>/dev/null )"
	MY_PORT_HTTP="$(cat ${CONFIG_DIR}/3proxy.cfg | grep "^proxy -p" | awk -F "-p" '{print $2}') | sort | uniq | tail -n 1"
	MY_PORT_SOCKS="$(cat ${CONFIG_DIR}/3proxy.cfg | grep "^socks -p" | awk -F "-p" '{print $2}') | sort | uniq | tail -n 1"
	echo ""
	echo ""
	echo ""
	echo "=================================================================="
	echo "IPv4 адрес вашего прокси-сервера: $MY_IPv4"
	echo "IPv6 адрес вашего прокси-сервера: $MY_IPv6"
	echo "Порт вашего HTTP(S) прокси: $MY_PORT_HTTP"
	echo "Порт вашего SOCKS-прокси: $MY_PORT_SOCKS"
	echo "=================================================================="
	echo ""
}

service_restart(){
	if service "$1" restart
		then
			echo "Сервис 3proxy успешно (пере)запущен!"
		else
			echo_err "ОШИБКА (пере)запуска сервиса 3proxy!"
	fi
}

print_users(){
	echo ""
	echo "Список текущих пользователей прокси-сервера 3proxy:"
	while read -r line
	do
		username="$(echo "$line" | awk -F ":CL:" '{print $1}')"
		userpassword="$(echo "$line" | awk -F ":CL:" '{print $2}')"
		echo "Логин: $username"
		echo "Пароль: $userpassword"
		echo ""
	done < "$CONFIG_DIR/3proxy.cfg.auth"
}
user_add(){
	while true
	do
		echo ""
		echo "Введите желаемое имя пользователя (логин) для нового пользователя прокси-сервера:"
		read -r new_username
		echo "Введите пароль для нового пользователя с логином $new_username"
		read -r new_userpassword
		if [ ! -z "$new_username" ] && [ ! -z "$new_userpassword" ]
			then
				break
			else
				echo "Вы не ввели либо логин, либо пароль, попробуйте еще раз!"
		fi
	done
	if [ ! -f "$CONFIG_DIR/3proxy.cfg.auth" ]
		then
			touch "$CONFIG_DIR/3proxy.cfg.auth"
			chown proxy:proxy "$CONFIG_DIR/3proxy.cfg.auth"
			chmod 400 "$CONFIG_DIR/3proxy.cfg.auth"
	fi
	if echo "${new_username}:CL:${new_userpassword}" >>"$CONFIG_DIR/3proxy.cfg.auth"
		then
			echo "Пользователь добавлен"
			if [ "$1" = 'show_users' ]
				then
					read_p "Нажмите Enter, чтобы показать список пользователей и перезапустить прокси-сервер или Ctrl+C для выхода"
					print_users
			fi
		else
		 echo_err "Ошибка добавления пользователя!"
	fi
}

user_delete(){
	while true
	do
		echo ""
		echo "Введите имя удаляемого пользователя"
		read -r del_username
		if [ ! -z "$del_username" ]
			then
				break
			else
				echo "Вы не ввели логин удаляемого пользователя, попробуйте еще раз! Если вы не помните логин, то нажмите Ctrl+C и выполните команду ./freebsd-autodeploy.sh listusers для вывода списка пользователей прокси-сервера"
		fi
		if sed "/^${del_username}/d" "$CONFIG_DIR/3proxy.cfg.auth"
			then
				echo "Пользователь ${del_username} успешно удален."
			else
				echo_err "Ошибка удаления пользователя ${del_username}; возможно вы ввели неправильное имя пользователя"
		fi
	done
}

##################################################################################
case "$1" in
	"adduser")
		user_add show_users
		#print_users
		service_restart 3proxy
	;;
	"deluser")
		user_delete
		#print_users
		service_restart 3proxy
	;;
	"3proxy-setup")
		freebsd_initial_setup
		proxy_setup
		user_add
		service_restart 3proxy
		print_server_info
	;;
	"setup-freebsd")
		freebsd_initial_setup
	;;
	"listusers")
		print_users
	;;
	"serverinfo")
		print_server_info
	;;
	*)
		echo_help
	;;
esac
