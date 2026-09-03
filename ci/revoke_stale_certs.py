"""Revoca los certificados de desarrollo que dejaron atrás runs anteriores.

El archive usa -allowProvisioningUpdates, que en un runner efímero encuentra el
llavero vacío y le pide a Apple un certificado de desarrollo nuevo. Su clave
privada muere con el runner, así que cada uno es basura en cuanto acaba el job,
pero sigue ocupando sitio en el cupo de la cuenta. El cupo es compartido por
todas las apps: cuando se llena, dejan de archivar todas a la vez.

Revocarlos aquí, antes del archive, mantiene como mucho uno vivo a la vez.

Solo se tocan los certificados cuyo displayName es exactamente "Created via API":
los de Álvaro llevan su nombre, y los de distribución nunca son candidatos.

ponytail: si dos runs coinciden en el tiempo, una puede revocar el certificado que
la otra está usando y esa fallará. Con un repo de una persona no compensa
coordinarlo; si algún día molesta, filtrar por fecha de creación.
"""

import json
import os
import time
import urllib.error
import urllib.request

import jwt

KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
KEY_PATH = os.path.expanduser(f"~/private_keys/AuthKey_{KEY_ID}.p8")
BASE = "https://api.appstoreconnect.apple.com"

THROWAWAY_NAME = "Created via API"
THROWAWAY_TYPE = "DEVELOPMENT"


def token():
    with open(KEY_PATH) as handle:
        key = handle.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


def call(method, path):
    request = urllib.request.Request(
        BASE + path, method=method, headers={"Authorization": f"Bearer {token()}"}
    )
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        return error.code, json.loads(raw) if raw else {}


status, data = call("GET", "/v1/certificates?limit=200")
if status != 200:
    raise SystemExit(f"no se pudo listar certificados: {status}")

stale = [
    cert["id"]
    for cert in data.get("data", [])
    if cert["attributes"].get("certificateType") == THROWAWAY_TYPE
    and cert["attributes"].get("displayName") == THROWAWAY_NAME
]

print(f"certificados en la cuenta: {len(data.get('data', []))}")
print(f"desechables de runs anteriores: {len(stale)}")

for cert_id in stale:
    status, _ = call("DELETE", f"/v1/certificates/{cert_id}")
    print(f"  revocado {cert_id}: {status}")
