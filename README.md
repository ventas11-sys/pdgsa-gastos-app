# Reporte de Gastos Colaborador · Solicitudes de Pago

Aplicación web **responsive + móvil** para que los colaboradores carguen
gastos con foto del recibo, y para que **Contabilidad** los revise y
**Tesorería** los pague. Un **Super Admin** gestiona cuentas, proyectos,
empresas y la marca.

Corre desde **GitHub Pages** (hosting gratis) y guarda todo en
**Supabase** (Postgres + Storage + Auth).

- **Login real** por correo + contraseña
- **Foto directa desde el celular** (cámara trasera) o subida de PDF/imagen
- **Sincronización automática** — todo queda en la nube
- **Workflow con 7 estados** y bandeja de revisión por rol
- **Auditoría completa**: cada acción queda registrada con autor y fecha
- **Personalización** de logo, nombre y colores por empresa
- **Contraseñas centralizadas**: solo el Super Admin las asigna y las cambia — el usuario no puede resetearlas por su cuenta

---

## 🧭 Roles y flujo

| Rol            | Qué puede hacer                                                                 |
| -------------- | ------------------------------------------------------------------------------- |
| `colaborador`  | Crea solicitudes, adjunta recibos, edita mientras estén en borrador o corregir  |
| `contabilidad` | Ve todas las solicitudes, aprueba, pide corrección o rechaza                    |
| `tesoreria`    | Ve las aprobadas por contabilidad y marca como pagadas o rechaza                |
| `super_admin`  | Todo lo anterior + gestiona usuarios, proyectos, empresas PDG y la marca        |

**Flujo de una solicitud:**

```
[colaborador]                  [contabilidad]                 [tesorería]
    │                                │                              │
    ▼                                ▼                              ▼
borrador ─envío──▶ enviado ──aprobar──▶ aprobado_contabilidad ──pagar──▶ pagado
                     │                       │
                  corregir ◀─┐            rechazar_teso
                  rechazado ◀┘
                     ▲
                     └── el colaborador ajusta y reenvía
```

El colaborador ve el estado en tiempo real y, si le piden corregir, lee el
motivo, ajusta y reenvía.

---

## 📝 Campos de la solicitud

Todos los del formato "SOLICITUD DE PAGO PDG" están incluidos:

- **Número de solicitud** (auto: `SP-YYYYMM-NNNN`)
- **Proyecto al que se imputa** (dropdown o manual)
- **Empresa PDG** que factura (dropdown — se manejan varias razones sociales)
- **Fecha del gasto**
- **Detalle / concepto**
- **Proveedor / Comercio**, **RUC** y **DV**
- **Monto neto**, **ITBMS** (la app calcula el total automáticamente)
- **Medio de pago**: Tarjeta corporativa · Efectivo · ACH · Cheque · Yappy
- **Cuenta bancaria / referencia** (obligatoria para ACH, cheque, Yappy)
- **Adjuntos** (foto del recibo + comprobantes) — obligatorio para enviar

---

## 🚀 Puesta en marcha (30 min)

### 1) Crear proyecto en Supabase

1. Entra a <https://supabase.com> y crea una cuenta (con GitHub sirve).
2. **New project** → nombre `gastos-pdg`, guarda la contraseña de la BD,
   selecciona región cercana (South America - São Paulo).
3. Esperá ~2 min a que provisione.

### 2) Correr el schema

1. En el panel del proyecto → **SQL Editor → New query**.
2. Abre `supabase-schema.sql`, copia TODO el contenido y pégalo.
3. Clic **Run**. Deberías ver "Success. No rows returned".

### 3) Crear el bucket de Storage

1. **Storage → New bucket** → nombre exacto: `expense-attachments`
2. **Private bucket** (NO marques público)
3. Guardar. (Las policies ya se crearon en el paso 2.)

### 4) Configurar Auth

1. **Authentication → Providers → Email**
   - Habilitá "Email".
   - **Desactivá "Confirm email"** (necesario para que crear usuarios desde la
     app funcione sin verificación manual).
2. **Authentication → Users → Add user → Create new user**
   - Email: `admin@pdgsa.com` (o el tuyo)
   - Password: uno fuerte (mínimo 6 caracteres)
   - Auto Confirm User: ✅
3. Volvé al **SQL Editor** y ejecutá (cambiando el correo):
   ```sql
   update public.profiles
     set role = 'super_admin', name = 'Maximiliano Alcaide'
     where email = 'admin@pdgsa.com';
   ```

### 5) Copiar credenciales a la app

1. **Project Settings → API**
2. Copiá:
   - **Project URL** → `https://xxxxx.supabase.co`
   - **anon public key** → un token largo que empieza con `eyJ…`
3. Abre `config.js` y pegá ambas:
   ```js
   window.APP_CONFIG = {
     SUPABASE_URL: 'https://xxxxx.supabase.co',
     SUPABASE_ANON_KEY: 'eyJhbGci…',
     STORAGE_BUCKET: 'expense-attachments'
   };
   ```
   > La anon key es pública por diseño de Supabase. La seguridad real está
   > en las políticas RLS del schema. **NUNCA** pongas la `service_role` key
   > en `config.js`.

### 6) Deploy de la Edge Function `admin-user`

Esta función permite al Super Admin cambiar contraseñas, correos y borrar
usuarios sin exponer la `service_role` key en el navegador.

**Opción A — Editor web de Supabase (más fácil)**

1. **Edge Functions → Create a new function**
2. Nombre: `admin-user`. Clic **Create function**.
3. Abre `supabase/functions/admin-user/index.ts`, copia todo, pégalo.
4. Clic **Deploy function**.
5. **Function settings → Verify JWT → Desactivar** el toggle.
6. **Function settings → Secrets → Add secret**:
   - `SUPABASE_URL` = tu Project URL
   - `SUPABASE_ANON_KEY` = tu anon key
   - `SUPABASE_SERVICE_ROLE_KEY` = **Project Settings → API → service_role key**
     ⚠️ Esta key NO va en `config.js`. Solo vive dentro de la Edge Function.

**Opción B — Supabase CLI**

```bash
npm i -g supabase
supabase login
supabase link --project-ref TU_PROJECT_REF
supabase functions deploy admin-user --no-verify-jwt
supabase secrets set SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=...
```

### 7) Subir a GitHub y activar GitHub Pages

```bash
cd pdgsa-gastos-app
git init
git add -A
git commit -m "primer commit"
```

Después, en <https://github.com>:

1. **New repository** → nombre `pdgsa-gastos-app` → **Private** → Create.
2. Copiá los comandos que da GitHub:
   ```bash
   git remote add origin https://github.com/TU_USUARIO/pdgsa-gastos-app.git
   git branch -M main
   git push -u origin main
   ```
3. En el repo → **Settings → Pages → Branch: main / (root)** → Save.
4. En ~1 min queda en `https://TU_USUARIO.github.io/pdgsa-gastos-app/`.

### 8) ¡Listo!

Entrá desde tu celular. Iniciá sesión con el Super Admin creado.
Desde **Perfil → Gestionar usuarios**, creá las cuentas del equipo:
Yohana (colaborador), quien esté en Contabilidad, quien esté en Tesorería.

---

## 📱 Instalar como app en el celular

- **Android/Chrome**: abrí la URL → menú (⋮) → "Añadir a pantalla de inicio"
- **iPhone/Safari**: abrí la URL → botón compartir → "Añadir a pantalla de inicio"

Queda con ícono propio y se abre a pantalla completa. La cámara del
teléfono se abre directamente desde el botón "Sacar foto" del wizard.

---

## 🗂 Proyectos y empresas iniciales

El schema deja creados:

- **Proyectos**: Lomas de San Francisco, Almirante Bay, Jardines, Administración
- **Empresa**: PDGSA (RUC vacío — completá desde la app)

Editá / agregá desde **Perfil → Proyectos y empresas** (solo Super Admin).

---

## 🔒 Seguridad

- Row Level Security (RLS) en TODAS las tablas.
- El colaborador **solo ve sus propias solicitudes**; los revisores ven todo.
- El bucket de Storage tiene policies que solo permiten leer un archivo si
  sos el dueño de la solicitud o un revisor.
- La `service_role` key nunca sale del servidor (vive en la Edge Function).
- Un colaborador solo puede editar/eliminar sus solicitudes en estado
  `borrador` o `corregir`. Una vez aprobada o pagada, queda inmutable
  para el colaborador.
- **Contraseñas centralizadas**: la UI no expone ningún flujo de
  "cambiar mi contraseña" ni de "olvidé mi contraseña". El único camino
  es que el Super Admin la asigne desde **Usuarios → Contraseña**.

---

## 🧯 Troubleshooting

- **"Credenciales incorrectas"** aunque el usuario existe: revisá que
  "Auto Confirm" esté ✅ o confirmá el correo desde el link de Supabase.
- **Colaborador ve la lista vacía**: normal — hasta que él mismo cree la
  primera solicitud. Si ya cargó y no la ve, revisá `profiles.role`.
- **"Cuenta sin perfil"**: el trigger no corrió. Ejecutá manualmente:
  ```sql
  insert into profiles (id, name, email, role)
  values ('<uuid>', 'Nombre', '<email>', 'colaborador');
  ```
- **Cámara no se abre**: iOS requiere que el sitio esté servido por HTTPS
  (GitHub Pages ya cumple). En localhost sin HTTPS solo funciona en Chrome.
- **Error al subir archivo**: revisá que el bucket `expense-attachments`
  exista y sea privado, y que las policies de storage se hayan creado
  (paso 2 del schema).

---

## 🧰 Estructura

```
pdgsa-gastos-app/
├─ index.html                 ← la app completa (HTML + CSS + JS)
├─ config.js                  ← tu URL + anon key de Supabase
├─ supabase-schema.sql        ← esquema Postgres + RLS + policies storage
├─ supabase/functions/
│   └─ admin-user/index.ts    ← Edge Function para el Super Admin
└─ README.md
```

---

## 💾 Estados soportados

| Estado                    | Significado                                          |
| ------------------------- | ---------------------------------------------------- |
| `borrador`                | Guardado por el colaborador, no enviado              |
| `enviado`                 | En bandeja de contabilidad                           |
| `corregir`                | Contabilidad pidió ajustes                           |
| `rechazado`               | Contabilidad rechazó definitivamente                 |
| `aprobado_contabilidad`   | En bandeja de tesorería, esperando pago              |
| `pagado`                  | Tesorería confirmó el pago                           |
| `rechazado_tesoreria`     | Tesorería rechazó (ej. datos bancarios erróneos)     |
