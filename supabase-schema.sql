-- ============================================================
-- GASTOS PDG · Esquema Supabase
-- ============================================================
-- Uso:
--   1. En tu proyecto Supabase → SQL Editor → New query
--   2. Pega TODO este archivo y corre ("Run")
--   3. Storage → New bucket → nombre "expense-attachments" (private)
--   4. Authentication → Providers → Email habilitado, "Confirm email" OFF
--   5. Authentication → Users → Add user (super admin)
--   6. Correr al final:
--        update public.profiles set role='super_admin', name='Tu Nombre'
--        where email='admin@pdgsa.com';
-- ============================================================

-- ================ TABLA: profiles ==========================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  email text not null,
  phone text,
  role text not null default 'colaborador'
    check (role in ('colaborador','contabilidad','tesoreria','super_admin')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ================ TABLA: projects (proyectos PDG) ==========
create table if not exists public.projects (
  id text primary key,
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ================ TABLA: companies (razones sociales PDG) ==
create table if not exists public.companies (
  id text primary key,
  name text not null,
  ruc text not null,
  dv text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ================ TABLA: expense_requests ==================
-- status:
--   borrador               → guardado por el colaborador, aún no enviado
--   enviado                → esperando revisión de contabilidad
--   corregir               → contabilidad pide ajustes al colaborador
--   rechazado              → contabilidad rechaza definitivamente
--   aprobado_contabilidad  → esperando pago por tesorería
--   pagado                 → tesorería confirmó el pago
--   rechazado_tesoreria    → tesorería rechaza (devuelve o cierra)
create table if not exists public.expense_requests (
  id text primary key,
  number text unique,
  requester_id uuid references auth.users(id) on delete set null,
  requester_name text,
  project_id text references public.projects(id) on delete set null,
  project_name text,
  company_id text references public.companies(id) on delete set null,
  company_name text,
  company_ruc text,
  provider_name text,
  provider_ruc text,
  provider_dv text,
  expense_date date,
  description text,
  net_amount numeric(12,2) not null default 0,
  itbms numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  payment_method text
    check (payment_method in ('tarjeta','efectivo','ach','cheque','yappy') or payment_method is null),
  bank_account text,
  status text not null default 'borrador'
    check (status in ('borrador','enviado','corregir','rechazado','aprobado_contabilidad','pagado','rechazado_tesoreria')),
  submitted_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_notes text,
  paid_by uuid references auth.users(id) on delete set null,
  paid_at timestamptz,
  payment_ref text,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists expense_requests_requester_idx on public.expense_requests(requester_id);
create index if not exists expense_requests_status_idx    on public.expense_requests(status);
create index if not exists expense_requests_date_idx      on public.expense_requests(expense_date desc);

-- ================ TABLA: expense_attachments ==============
create table if not exists public.expense_attachments (
  id text primary key,
  expense_id text not null references public.expense_requests(id) on delete cascade,
  kind text not null default 'recibo',   -- 'recibo', 'comprobante', 'otro'
  file_name text not null,
  storage_path text not null,            -- ruta dentro del bucket
  mime_type text,
  size_bytes bigint,
  uploaded_by uuid references auth.users(id) on delete set null,
  uploaded_at timestamptz not null default now()
);
create index if not exists expense_attachments_exp_idx on public.expense_attachments(expense_id);

-- ================ TABLA: expense_events (histórico) ========
create table if not exists public.expense_events (
  id bigserial primary key,
  expense_id text not null references public.expense_requests(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  actor_name text,
  actor_role text,
  event_type text not null,              -- 'crear','enviar','corregir','rechazar','aprobar','pagar','comentar','editar'
  from_status text,
  to_status text,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists expense_events_exp_idx on public.expense_events(expense_id);

-- ================ TABLA: app_settings ======================
create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

-- ================ GRANTS ===================================
grant usage on schema public to authenticated, anon, service_role;
grant all on public.profiles            to authenticated, anon, service_role;
grant all on public.projects            to authenticated, anon, service_role;
grant all on public.companies           to authenticated, anon, service_role;
grant all on public.expense_requests    to authenticated, anon, service_role;
grant all on public.expense_attachments to authenticated, anon, service_role;
grant all on public.expense_events      to authenticated, anon, service_role;
grant usage, select on sequence public.expense_events_id_seq to authenticated, anon, service_role;
grant all on public.app_settings        to authenticated, anon, service_role;

-- ================ TRIGGER: updated_at ======================
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;$$;

drop trigger if exists touch_expense_requests on public.expense_requests;
create trigger touch_expense_requests before update on public.expense_requests
  for each row execute function public.touch_updated_at();

-- ================ TRIGGER: nuevo perfil al sign-up =========
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, name, email, phone, role, active)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)),
    new.email,
    new.raw_user_meta_data->>'phone',
    coalesce(new.raw_user_meta_data->>'role', 'colaborador'),
    true
  )
  on conflict (id) do nothing;
  return new;
end;$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ================ HELPERS: roles ===========================
create or replace function public.current_role_v()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

create or replace function public.is_super_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select role='super_admin' from public.profiles where id=auth.uid()), false)
$$;

create or replace function public.is_contabilidad()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('contabilidad','super_admin') from public.profiles where id=auth.uid()), false)
$$;

create or replace function public.is_tesoreria()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('tesoreria','super_admin') from public.profiles where id=auth.uid()), false)
$$;

create or replace function public.can_review_all()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('contabilidad','tesoreria','super_admin')
                   from public.profiles where id=auth.uid()), false)
$$;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table public.profiles            enable row level security;
alter table public.projects            enable row level security;
alter table public.companies           enable row level security;
alter table public.expense_requests    enable row level security;
alter table public.expense_attachments enable row level security;
alter table public.expense_events      enable row level security;
alter table public.app_settings        enable row level security;

-- ------- profiles -------
drop policy if exists profiles_read_own on public.profiles;
create policy profiles_read_own on public.profiles
  for select using (auth.uid() = id);

drop policy if exists profiles_read_all_review on public.profiles;
create policy profiles_read_all_review on public.profiles
  for select using (public.can_review_all());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists profiles_update_all_super on public.profiles;
create policy profiles_update_all_super on public.profiles
  for update using (public.is_super_admin()) with check (public.is_super_admin());

drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles
  for insert with check (auth.uid() = id or public.is_super_admin());

drop policy if exists profiles_delete_super on public.profiles;
create policy profiles_delete_super on public.profiles
  for delete using (public.is_super_admin());

-- ------- projects -------
drop policy if exists projects_read on public.projects;
create policy projects_read on public.projects
  for select using (auth.role() = 'authenticated');

drop policy if exists projects_write on public.projects;
create policy projects_write on public.projects
  for insert with check (public.is_super_admin());

drop policy if exists projects_update on public.projects;
create policy projects_update on public.projects
  for update using (public.is_super_admin()) with check (public.is_super_admin());

drop policy if exists projects_delete on public.projects;
create policy projects_delete on public.projects
  for delete using (public.is_super_admin());

-- ------- companies -------
drop policy if exists companies_read on public.companies;
create policy companies_read on public.companies
  for select using (auth.role() = 'authenticated');

drop policy if exists companies_write on public.companies;
create policy companies_write on public.companies
  for insert with check (public.is_super_admin());

drop policy if exists companies_update on public.companies;
create policy companies_update on public.companies
  for update using (public.is_super_admin()) with check (public.is_super_admin());

drop policy if exists companies_delete on public.companies;
create policy companies_delete on public.companies
  for delete using (public.is_super_admin());

-- ------- expense_requests -------
-- Colaborador: ve las propias. Contabilidad/Tesorería/Super: ven todas.
drop policy if exists expense_requests_read on public.expense_requests;
create policy expense_requests_read on public.expense_requests
  for select using (
    requester_id = auth.uid() or public.can_review_all()
  );

drop policy if exists expense_requests_insert on public.expense_requests;
create policy expense_requests_insert on public.expense_requests
  for insert with check (
    auth.role() = 'authenticated' and
    (requester_id = auth.uid() or public.can_review_all())
  );

-- Colaborador solo puede editar mientras esté en borrador o corregir
drop policy if exists expense_requests_update on public.expense_requests;
create policy expense_requests_update on public.expense_requests
  for update using (
    (requester_id = auth.uid() and status in ('borrador','corregir'))
    or public.can_review_all()
  ) with check (
    (requester_id = auth.uid() and status in ('borrador','corregir','enviado'))
    or public.can_review_all()
  );

drop policy if exists expense_requests_delete on public.expense_requests;
create policy expense_requests_delete on public.expense_requests
  for delete using (
    (requester_id = auth.uid() and status = 'borrador')
    or public.is_super_admin()
  );

-- ------- expense_attachments -------
drop policy if exists expense_attachments_read on public.expense_attachments;
create policy expense_attachments_read on public.expense_attachments
  for select using (
    exists (select 1 from public.expense_requests e
            where e.id = expense_id
              and (e.requester_id = auth.uid() or public.can_review_all()))
  );

drop policy if exists expense_attachments_insert on public.expense_attachments;
create policy expense_attachments_insert on public.expense_attachments
  for insert with check (
    exists (select 1 from public.expense_requests e
            where e.id = expense_id
              and (e.requester_id = auth.uid() or public.can_review_all()))
  );

drop policy if exists expense_attachments_delete on public.expense_attachments;
create policy expense_attachments_delete on public.expense_attachments
  for delete using (
    exists (select 1 from public.expense_requests e
            where e.id = expense_id
              and ((e.requester_id = auth.uid() and e.status in ('borrador','corregir'))
                   or public.is_super_admin()))
  );

-- ------- expense_events -------
drop policy if exists expense_events_read on public.expense_events;
create policy expense_events_read on public.expense_events
  for select using (
    exists (select 1 from public.expense_requests e
            where e.id = expense_id
              and (e.requester_id = auth.uid() or public.can_review_all()))
  );

drop policy if exists expense_events_insert on public.expense_events;
create policy expense_events_insert on public.expense_events
  for insert with check (
    auth.role() = 'authenticated' and
    exists (select 1 from public.expense_requests e
            where e.id = expense_id
              and (e.requester_id = auth.uid() or public.can_review_all()))
  );

-- ------- app_settings -------
drop policy if exists app_settings_read on public.app_settings;
create policy app_settings_read on public.app_settings
  for select using (auth.role() = 'authenticated');

drop policy if exists app_settings_write on public.app_settings;
create policy app_settings_write on public.app_settings
  for insert with check (public.is_super_admin());

drop policy if exists app_settings_update on public.app_settings;
create policy app_settings_update on public.app_settings
  for update using (public.is_super_admin()) with check (public.is_super_admin());

-- ============================================================
-- STORAGE: policies para bucket "expense-attachments"
-- ============================================================
-- Crea el bucket ANTES (Storage → New bucket → "expense-attachments" PRIVADO)
-- Convención de ruta: <expense_id>/<uuid>-<filename>
do $$ begin
  -- Insert: solo autenticados
  begin
    execute $p$ create policy "storage_insert_own_expense" on storage.objects
      for insert to authenticated
      with check ( bucket_id = 'expense-attachments' ) $p$;
  exception when duplicate_object then null; end;

  -- Select: dueño de la solicitud o revisor
  begin
    execute $p$ create policy "storage_read_expense" on storage.objects
      for select to authenticated
      using (
        bucket_id = 'expense-attachments'
        and exists (
          select 1 from public.expense_requests e
          where e.id = split_part(name, '/', 1)
            and (e.requester_id = auth.uid() or public.can_review_all())
        )
      ) $p$;
  exception when duplicate_object then null; end;

  -- Delete: dueño mientras esté en borrador/corregir, o super_admin
  begin
    execute $p$ create policy "storage_delete_expense" on storage.objects
      for delete to authenticated
      using (
        bucket_id = 'expense-attachments'
        and exists (
          select 1 from public.expense_requests e
          where e.id = split_part(name, '/', 1)
            and ((e.requester_id = auth.uid() and e.status in ('borrador','corregir'))
                 or public.is_super_admin())
        )
      ) $p$;
  exception when duplicate_object then null; end;
end $$;

-- ============================================================
-- SEED: proyectos y empresas iniciales
-- ============================================================
insert into public.projects (id, name) values
  ('it',                              'IT'),
  ('marketing',                       'Marketing'),
  ('logistica-transporte-eb',         'Logística - Transporte - EB'),
  ('jardines-del-frances',            'Jardines del Francés'),
  ('km',                              'KM'),
  ('etesa-veladero',                  'ETESA Veladero'),
  ('canta-gallo',                     'Canta Gallo'),
  ('iphe-porky',                      'IPHE Porky'),
  ('utp-centennial',                  'UTP - Centennial'),
  ('casa-percy',                      'Casa Percy'),
  ('442',                             '442'),
  ('iphe-aguadulce',                  'IPHE Aguadulce'),
  ('media-cancha-chitre',             'Media Cancha Chitré'),
  ('aeronautica-aerodromo-penonome',  'Aeronáutica - Aeródromo Penonomé'),
  ('aeronautica-aerodromo-chitre',    'Aeronáutica - Aeródromo Chitré'),
  ('lomas-san-francisco',             'Lomas San Francisco'),
  ('almirante-bay',                   'Almirante Bay'),
  ('santiago-green-house',            'Santiago Green House'),
  ('inadeh-darien',                   'INADEH Darién'),
  ('santamaria-848',                  'Santamaría - 848'),
  ('generales',                       'Generales'),
  ('ventas',                          'Ventas'),
  ('tramites-hipotecarios',           'Trámites Hipotecarios'),
  ('gubernamentales',                 'Gubernamentales'),
  ('administrativos',                 'Administrativos')
on conflict (id) do nothing;

insert into public.companies (id, name, ruc, dv) values
  ('pdgsa', 'Proyectos y Desarrollo Grupal S.A. (PDGSA)', '', '')
on conflict (id) do nothing;

-- ============================================================
-- Nota sobre usuarios
-- ============================================================
-- Los usuarios NO se crean por SQL: hay que crearlos por Supabase Auth
-- (con su contraseña hasheada). Opciones:
--   1) Desde la app (Perfil → Gestionar usuarios) una vez creado el primer
--      super_admin siguiendo los pasos del README.
--   2) Desde el panel de Supabase → Authentication → Users → Add user.
--
-- Lista sugerida de usuarios PDG (crear luego desde la app):
--
--   Super Admin
--     Maximiliano Alcaide      maximiliano.alcaide@pdgsa.com
--
--   Colaboradores
--     Eroz Moreno              soporte02@pdgsa.com
--     Ameth Navarro            ameth.navarro@pdgsa.com
--     Ricardo Sánchez          produccion.occidente@pdgsa.com
--     Ricardo Caballero        produccion.occidente2@pdgsa.com
--     Dimas Stapf              produccion.metro@pdgsa.com
--     Edwin Ríos               edwin.rios@pdgsa.com
--     Luis Pinzón              produccion.oeste@pdgsa.com
--     César Prescott           cesarprescott270101@gmail.com
--     Luis Lezcano             luis.lezcano@pdgsa.com
--     Saray Cantillo           saray.cantillo@pdgsa.com
--     Yohana Cerrud            yohana.cerrud@pdgsa.com
--     Yarlenis Jaramillo       yarlenis.jaramillo@pdgsa.com
--
--   Contabilidad
--     Marlene Valdés           marlene.valdes@pdgsa.com
--     Ernesto Bosquez          ernesto.bosquez@pdgsa.com
--     Agustin Sanjur           agustin.sanjur@pdgsa.com
--
--   Tesorería
--     Giovana Rivera           contabilidad.supervision@pdgsa.com
--     Alicia Hernandez         contabilidad01@pdgsa.com
--     Lisbiela Muñoz           contabilidad02@pdgsa.com

-- ============================================================
-- OPCIONAL: primer super admin (edita el correo antes de correr)
-- ============================================================
-- update public.profiles set role='super_admin', name='Maximiliano Alcaide'
-- where email='maximiliano.alcaide@pdgsa.com';
