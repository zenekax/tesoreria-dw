"""Workaround macOS: hace que el ODBC Driver 18 cargue OpenSSL 3 aunque no actives el venv.

scripts/setup_python.sh copia este archivo al site-packages del venv (con la ruta real de
openssl@3) y agrega un `.pth` que lo importa. Python ejecuta los `.pth` al arrancar.

Por qué un relanzamiento: macOS (dyld) lee DYLD_LIBRARY_PATH solo cuando arranca el
proceso, así que setearla en os.environ desde adentro no sirve. Si falta, se vuelve a
ejecutar el mismo comando (sys.orig_argv) una única vez con la variable puesta. La marca
TDW_OPENSSL_REEXEC evita un bucle si el sistema la descarta (por ejemplo, con SIP).
"""
import os
import sys

_LIB = "__SSL3_LIB__"

if sys.platform == "darwin" and not os.environ.get("TDW_OPENSSL_REEXEC"):
    _actual = os.environ.get("DYLD_LIBRARY_PATH", "")
    if _LIB not in _actual.split(":") and os.path.isdir(_LIB):
        _env = dict(os.environ, TDW_OPENSSL_REEXEC="1",
                    DYLD_LIBRARY_PATH=":".join(p for p in (_LIB, _actual) if p))
        os.execve(sys.executable, sys.orig_argv, _env)
