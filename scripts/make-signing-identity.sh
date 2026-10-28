#!/bin/bash
# Створює локальний сертифікат для підпису Cleaner в ОКРЕМОМУ ключ-зв'язку (~/.cleaner-signing).
#
# Навіщо: при ad-hoc підписі macOS скидає Full Disk Access після кожної перезбірки, бо підпис
# прив'язаний до хешу збірки. Зі стабільним сертифікатом дозвіл зберігається між збірками.
#
# Що робить (і що ні):
#   • створює папку ~/.cleaner-signing з окремим ключ-зв'язком signing.keychain-db;
#   • кладе туди самопідписаний сертифікат "Cleaner Local Signing" (діє 10 років);
#   • НЕ чіпає твій основний ключ-зв'язок (login), НЕ змінює список ключ-зв'язків системи;
#   • НЕ довіряє сертифікату в системі: він потрібен лише, щоб підпис був однаковий від збірки до збірки.
# Прибрати все: rm -rf ~/.cleaner-signing
#
# Запускати один раз. Повторний запуск нічого не ламає. build-app.sh сам використає цей
# сертифікат, якщо він є, а якщо ні, підпише ad-hoc, як раніше.
set -euo pipefail

DIR="$HOME/.cleaner-signing"
KEYCHAIN="$DIR/signing.keychain-db"
NAME="Cleaner Local Signing"
PASS="cleaner-local"   # пароль лише від цього службового ключ-зв'язку

if [ -f "$KEYCHAIN" ] && security unlock-keychain -p "$PASS" "$KEYCHAIN" 2>/dev/null \
   && security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Сертифікат уже є: $KEYCHAIN"
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"
rm -f signing.keychain-db key.pem cert.pem identity.p12

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Старі алгоритми потрібні, щоб `security import` прочитав PKCS12, створений OpenSSL 3.
openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 -passout "pass:$PASS" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # без автоблокування
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import identity.p12 -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
# Дозволяє codesign користуватися ключем без запиту пароля.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null

rm -f key.pem identity.p12
echo "Готово: сертифікат «${NAME}» у ${KEYCHAIN}"
echo
echo "ЩЕ ОДИН КРОК, який виконуєш ТИ (скрипт його не робить): довіра сертифікату для підпису коду."
echo "Без неї codesign відмовляється підписувати («no identity found», статус NOT_TRUSTED)."
echo "Команда змінює налаштування довіри ЛИШЕ для твого користувача й ЛИШЕ для призначення «підпис коду»,"
echo "macOS покаже діалог із паролем:"
echo
echo "  security add-trusted-cert -r trustRoot -p codeSign -k \"$KEYCHAIN\" \"$DIR/cert.pem\""
echo
echo "Скасувати довіру: security remove-trusted-cert \"$DIR/cert.pem\"   (і rm -rf ~/.cleaner-signing)"
echo "Потім: scripts/build-app.sh --install, і видай Full Disk Access востаннє."
