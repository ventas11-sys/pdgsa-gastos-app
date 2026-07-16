-- ============================================================
-- GASTOS PDG · Migración v1.00 (2026-07-15)
-- ============================================================
-- Corré este archivo UNA VEZ en el SQL Editor de Supabase
-- (después de `supabase-schema.sql`). Es incremental: agrega
-- funcionalidad para "Solicitudes de Fondos" sin borrar nada.
--
-- Nuevo modelo:
--   fund_requests  ← el colaborador pide plata por adelantado
--   expense_requests.fund_request_id  ← vincula el gasto con la solicitud
--   expense_requests.item_ok          ← contabilidad marca OK por ítem
-- ============================================================

-- ================ TABLA: fund_requests =====================
-- status:
--   borrador               → guardado por el colaborador, aún no enviado
--   enviado                → esperando revisión de contabilidad
--   corregir               → contabilidad pide ajustes al colaborador
--   rechazado              → contabilidad rechaza definitivamente
--   aprobado_contabilidad  → esperando pago por tesorería
--   pagado                 → tesorería entregó los fondos (empieza a justificarse)
--   justificado            → colaborador cerró la carga de recibos
--   saldado                → contabilidad confirmó el balance (a favor / en contra / cuadrado)
--   rechazado_tesoreria    → tesorería rechaza (devuelve o cierra)
--
-- balance_kind:
--   pendiente     → aún no se cerró
--   cuadrado      → justificado == pedido
--   a_favor_pdg   → sobró plata, colaborador debe devolver
--   en_contra_pdg → faltó plata, PDG debe cubrir la diferencia
create table if not exists public.fund_requests (
  id text primary key,
  number text unique,
  requester_id uuid references auth.users(id) on delete set null,
  requester_name text,
  project_id text references public.projects(id) on delete set null,
  project_name text,
  company_id text references public.companies(id) on delete set null,
  company_name text,
  purpose text,                          -- para qué se pide la plata
  requested_amount numeric(12,2) not null default 0,
  requested_date date,
  needed_by date,                        -- para cuándo la necesita
  payment_method text
    check (payment_method in ('tarjeta','efectivo','ach','cheque','yappy') or payment_method is null),
  bank_account text,
  status text not null default 'borrador'
    check (status in ('borrador','enviado','corregir','rechazado','aprobado_contabilidad','pagado','justificado','saldado','rechazado_tesoreria')),
  submitted_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_notes text,
  paid_by uuid references auth.users(id) on delete set null,
  paid_at timestamptz,
  payment_ref text,
  justified_at timestamptz,              -- colaborador cerró la carga de recibos
  balance_kind text not null default 'pendiente'
    check (balance_kind in ('pendiente','cuadrado','a_favor_pdg','en_contra_pdg')),
  balance_diff numeric(12,2) not null default 0, -- requested - justificado (positivo=sobra, negativo=falta)
  balance_notes text,                    -- nota de cierre por contabilidad
  balance_closed_by uuid references auth.users(id) on delete set null,
  balance_closed_at timestamptz,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists fund_requests_requester_idx on public.fund_requests(requester_id);
create index if not exists fund_requests_status_idx    on public.fund_requests(status);
create index if not exists fund_requests_date_idx      on public.fund_requests(requested_date desc);

-- ================ Nuevos campos en expense_requests ========
alter table public.expense_requests
  add column if not exists fund_request_id text references public.fund_requests(id) on delete set null;
alter table public.expense_requests
  add column if not exists item_ok text
  check (item_ok in ('ok','revisar') or item_ok is null);
alter table public.expense_requests
  add column if not exists item_ok_by uuid references auth.users(id) on delete set null;
alter table public.expense_requests
  add column if not exists item_ok_at timestamptz;
alter table public.expense_requests
  add column if not exists item_ok_note text;
create index if not exists expense_requests_fund_idx on public.expense_requests(fund_request_id);

-- ================ GRANTS ===================================
grant all on public.fund_requests to authenticated, anon, service_role;

-- ================ TRIGGER: updated_at ======================
drop trigger if exists touch_fund_requests on public.fund_requests;
create trigger touch_fund_requests before update on public.fund_requests
  for each row execute function public.touch_updated_at();

-- ================ RLS ======================================
alter table public.fund_requests enable row level security;

-- Colaborador ve las propias; contabilidad/tesorería/super_admin ven todas
drop policy if exists fund_requests_read on public.fund_requests;
create policy fund_requests_read on public.fund_requests
  for select using (
    requester_id = auth.uid() or public.can_review_all()
  );

drop policy if exists fund_requests_insert on public.fund_requests;
create policy fund_requests_insert on public.fund_requests
  for insert with check (
    auth.role() = 'authenticated' and
    (requester_id = auth.uid() or public.can_review_all())
  );

-- Colaborador solo puede editar borrador/corregir
drop policy if exists fund_requests_update on public.fund_requests;
create policy fund_requests_update on public.fund_requests
  for update using (
    (requester_id = auth.uid() and status in ('borrador','corregir','pagado'))
    or public.can_review_all()
  ) with check (
    (requester_id = auth.uid() and status in ('borrador','corregir','enviado','pagado','justificado'))
    or public.can_review_all()
  );

drop policy if exists fund_requests_delete on public.fund_requests;
create policy fund_requests_delete on public.fund_requests
  for delete using (
    (requester_id = auth.uid() and status = 'borrador')
    or public.is_super_admin()
  );

-- ============================================================
-- Marca de versión en app_settings (opcional, informativo)
-- ============================================================
insert into public.app_settings (key, value)
values ('version', jsonb_build_object('name', 'v1.00', 'updated_at', '2026-07-15'))
on conflict (key) do update set value = excluded.value, updated_at = now();
