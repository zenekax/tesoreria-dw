#!/usr/bin/env bash
# Crea el venv del proyecto e instala dependencias. Idempotente: se puede correr N veces.
#
# Workaround macOS (verificado 19/11/2026): el ODBC Driver 18 (18.7.1.1) carga OpenSSL
# desde $(brew --prefix)/opt/openssl/lib, que Homebrew ahora apunta a OpenSSL 4.x.
# El driver solo soporta OpenSSL 1.0/1.1/3.0, así que la conexión falla con
# "OpenSSL library could not be loaded". Solución acotada al proyecto, sin tocar el sistema:
#   1) .venv/bin/python (activado o no, también desde VS Code) se relanza con
#      DYLD_LIBRARY_PATH -> openssl@3 (ver scripts/_tdw_openssl.py);
#   2) `source .venv/bin/activate` exporta la misma variable, para que sqlcmd ande en la terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v uv >/dev/null 2>&1; then
    [ -d .venv ] || uv venv --python 3.12 .venv
    uv pip install --python .venv/bin/python -r requirements.txt
else
    [ -d .venv ] || python3.12 -m venv .venv
    .venv/bin/python -m pip install -r requirements.txt
fi

if [ "$(uname -s)" = "Darwin" ]; then
    ssl3="$(brew --prefix openssl@3 2>/dev/null)/lib"
    if [ ! -f "$ssl3/libssl.3.dylib" ]; then
        echo "Falta OpenSSL 3. Instalalo con:  brew install openssl@3" >&2
        exit 1
    fi
    marca="# tesoreria-dw: OpenSSL 3 para el ODBC Driver 18"
    if ! grep -qF "$marca" .venv/bin/activate; then
        printf '\n%s\nexport DYLD_LIBRARY_PATH="%s${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"\n' \
            "$marca" "$ssl3" >> .venv/bin/activate
    fi
    # Se reescribe en cada corrida (idempotente) por si cambia la ruta de openssl@3.
    site="$(.venv/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
    sed "s|__SSL3_LIB__|$ssl3|" scripts/_tdw_openssl.py > "$site/_tdw_openssl.py"
    echo "import _tdw_openssl" > "$site/_tdw_openssl.pth"
fi

echo "Listo. Activá el entorno con:  source .venv/bin/activate"
