-- =====================================================================
--  GESTÃO DE PLANTÃO  |  Script de instalação do banco (Supabase)
--  Como usar: Supabase > SQL Editor > New query > cole TUDO > Run
--  Pode rodar de novo quando houver atualização: ele não apaga dados.
-- =====================================================================

-- ---------- 1. TABELAS (todas com hospital_id: pronto para vários hospitais) ----------
create table if not exists public.hospitais (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  cidade text,
  criado_em timestamptz not null default now()
);

create table if not exists public.setores (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitais(id) on delete cascade,
  nome text not null,
  cor text not null default '#971232',
  exige_aprovacao boolean not null default false,   -- troca precisa do OK do coordenador?
  permite_divisao boolean not null default true,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  unique (hospital_id, nome)
);

create table if not exists public.perfis (           -- 1 linha por usuário (médico ou coordenador)
  id uuid primary key references auth.users(id) on delete cascade,
  hospital_id uuid not null references public.hospitais(id),
  email text,
  nome text,
  nome_na_escala text,                               -- como o nome aparece no Excel (liga a planilha ao médico)
  crm text,
  uf_crm text,
  especialidade text,
  telefone text,
  papel text not null default 'medico' check (papel in ('medico','coordenador')),
  setores uuid[] not null default '{}',              -- setores em que o médico está habilitado
  ativo boolean not null default true,
  cadastro_completo boolean not null default false,
  aceite_lgpd_em timestamptz,
  criado_em timestamptz not null default now()
);
create unique index if not exists perfis_nome_escala_unico
  on public.perfis (hospital_id, lower(nome_na_escala)) where coalesce(nome_na_escala, '') <> '';

create table if not exists public.plantoes (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitais(id) on delete cascade,
  setor_id uuid not null references public.setores(id) on delete cascade,
  medico_id uuid references public.perfis(id) on delete set null,   -- vazio = plantão vago
  inicio timestamptz not null,
  fim timestamptz not null,
  tipo text not null default 'P24',
  valor numeric(10,2),
  status text not null default 'designado' check (status in ('designado','anunciado','vago')),
  origem_id uuid references public.plantoes(id) on delete set null, -- preenchido quando nasce de uma divisão
  checkin_em timestamptz,
  checkout_em timestamptz,
  observacao text,
  criado_em timestamptz not null default now(),
  constraint plantao_horario_valido check (fim > inicio)
);
create index if not exists plantoes_hospital_inicio on public.plantoes (hospital_id, inicio);
create index if not exists plantoes_medico_inicio on public.plantoes (medico_id, inicio);

create table if not exists public.solicitacoes (      -- trocas, passagens e anúncios
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitais(id) on delete cascade,
  tipo text not null check (tipo in ('troca','passagem','anuncio')),
  plantao_id uuid not null references public.plantoes(id) on delete cascade,
  plantao_contra_id uuid references public.plantoes(id) on delete cascade,  -- na troca: o plantão do colega
  solicitante_id uuid not null references public.perfis(id) on delete cascade,
  destinatario_id uuid references public.perfis(id) on delete set null,     -- colega ou candidato escolhido
  status text not null default 'pendente'
    check (status in ('pendente','aguardando_coordenador','concluida','recusada','cancelada')),
  mensagem text,
  motivo text,
  decidido_por uuid references public.perfis(id) on delete set null,
  aceito_em timestamptz,
  concluido_em timestamptz,
  criado_em timestamptz not null default now()
);
create unique index if not exists solicitacao_ativa_plantao on public.solicitacoes (plantao_id)
  where status in ('pendente','aguardando_coordenador');
create unique index if not exists solicitacao_ativa_contra on public.solicitacoes (plantao_contra_id)
  where plantao_contra_id is not null and status in ('pendente','aguardando_coordenador');

create table if not exists public.candidaturas (      -- quem quer assumir um plantão anunciado
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitais(id) on delete cascade,
  solicitacao_id uuid not null references public.solicitacoes(id) on delete cascade,
  medico_id uuid not null references public.perfis(id) on delete cascade,
  status text not null default 'ativa' check (status in ('ativa','escolhida','nao_escolhida','cancelada')),
  criado_em timestamptz not null default now(),
  unique (solicitacao_id, medico_id)
);

create table if not exists public.historico (         -- base do relatório de trocas e do fechamento
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitais(id) on delete cascade,
  tipo text not null,                                 -- troca, passagem, anuncio, divisao, ajuste
  plantao_id uuid references public.plantoes(id) on delete set null,
  solicitacao_id uuid references public.solicitacoes(id) on delete set null,
  de_medico_id uuid references public.perfis(id) on delete set null,
  para_medico_id uuid references public.perfis(id) on delete set null,
  setor_id uuid references public.setores(id) on delete set null,
  inicio timestamptz,
  fim timestamptz,
  detalhes text,
  feito_por uuid references public.perfis(id) on delete set null,
  criado_em timestamptz not null default now()
);
create index if not exists historico_hospital_inicio on public.historico (hospital_id, inicio);

-- ---------- 2. DADOS INICIAIS ----------
insert into public.hospitais (nome, cidade)
select 'Hospital Serrano', 'Nova Friburgo/RJ'
where not exists (select 1 from public.hospitais);

insert into public.setores (hospital_id, nome, cor)
select h.id, 'Clínica Médica', '#971232' from public.hospitais h
where not exists (select 1 from public.setores)
order by h.criado_em limit 1;

-- ---------- 3. FUNÇÕES DE APOIO ----------
create or replace function public.meu_hospital() returns uuid
language sql stable security definer set search_path = public as $$
  select hospital_id from perfis where id = auth.uid() and ativo;
$$;

create or replace function public.eh_coordenador() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select papel = 'coordenador' from perfis where id = auth.uid() and ativo), false);
$$;

create or replace function public._eu() returns public.perfis
language plpgsql stable security definer set search_path = public as $$
declare p perfis;
begin
  select * into p from perfis where id = auth.uid() and ativo;
  if p.id is null then raise exception 'Seu acesso não está ativo. Fale com a coordenação.'; end if;
  return p;
end $$;

create or replace function public._apto(p_medico uuid, p_setor uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfis where id = p_medico and ativo and p_setor = any(setores));
$$;

create or replace function public._conflito(p_medico uuid, p_inicio timestamptz, p_fim timestamptz, p_ignorar uuid[] default '{}')
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from plantoes
    where medico_id = p_medico and id <> all(array_remove(coalesce(p_ignorar, '{}'), null))
      and inicio < p_fim and fim > p_inicio);
$$;

create or replace function public._exige_aprovacao(p_plantao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select s.exige_aprovacao from plantoes p join setores s on s.id = p.setor_id where p.id = p_plantao), false);
$$;

-- ---------- 4. PERFIL AUTOMÁTICO PARA CADA USUÁRIO CRIADO ----------
create or replace function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
declare h uuid; primeiro boolean;
begin
  select id into h from hospitais order by criado_em limit 1;
  select not exists (select 1 from perfis) into primeiro;
  insert into perfis (id, hospital_id, email, papel)
  values (new.id, h, new.email, case when primeiro then 'coordenador' else 'medico' end)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.novo_usuario();

-- usuários criados antes deste script também ganham perfil
insert into public.perfis (id, hospital_id, email)
select u.id, (select id from public.hospitais order by criado_em limit 1), u.email
from auth.users u on conflict (id) do nothing;

-- se ainda não houver coordenador, o usuário mais antigo vira coordenador
update public.perfis set papel = 'coordenador'
where id = (select id from public.perfis order by criado_em limit 1)
  and not exists (select 1 from public.perfis where papel = 'coordenador');

-- ---------- 5. SEGURANÇA: cada pessoa só enxerga o próprio hospital ----------
alter table public.hospitais    enable row level security;
alter table public.setores      enable row level security;
alter table public.perfis       enable row level security;
alter table public.plantoes     enable row level security;
alter table public.solicitacoes enable row level security;
alter table public.candidaturas enable row level security;
alter table public.historico    enable row level security;

drop policy if exists hospitais_ler on public.hospitais;
create policy hospitais_ler on public.hospitais for select to authenticated using (id = meu_hospital());
drop policy if exists hospitais_coord on public.hospitais;
create policy hospitais_coord on public.hospitais for update to authenticated
  using (id = meu_hospital() and eh_coordenador()) with check (id = meu_hospital());

drop policy if exists setores_ler on public.setores;
create policy setores_ler on public.setores for select to authenticated using (hospital_id = meu_hospital());
drop policy if exists setores_coord on public.setores;
create policy setores_coord on public.setores for all to authenticated
  using (hospital_id = meu_hospital() and eh_coordenador())
  with check (hospital_id = meu_hospital() and eh_coordenador());

drop policy if exists perfis_ler on public.perfis;
create policy perfis_ler on public.perfis for select to authenticated using (hospital_id = meu_hospital());
drop policy if exists perfis_proprio on public.perfis;
create policy perfis_proprio on public.perfis for select to authenticated using (id = auth.uid());
drop policy if exists perfis_coord on public.perfis;
create policy perfis_coord on public.perfis for update to authenticated
  using (hospital_id = meu_hospital() and eh_coordenador())
  with check (hospital_id = meu_hospital());

drop policy if exists plantoes_ler on public.plantoes;
create policy plantoes_ler on public.plantoes for select to authenticated using (hospital_id = meu_hospital());
drop policy if exists plantoes_coord on public.plantoes;
create policy plantoes_coord on public.plantoes for all to authenticated
  using (hospital_id = meu_hospital() and eh_coordenador())
  with check (hospital_id = meu_hospital() and eh_coordenador());

drop policy if exists solicitacoes_ler on public.solicitacoes;
create policy solicitacoes_ler on public.solicitacoes for select to authenticated
  using (hospital_id = meu_hospital() and (eh_coordenador() or tipo = 'anuncio'
         or solicitante_id = auth.uid() or destinatario_id = auth.uid()));

drop policy if exists candidaturas_ler on public.candidaturas;
create policy candidaturas_ler on public.candidaturas for select to authenticated using (hospital_id = meu_hospital());

drop policy if exists historico_ler on public.historico;
create policy historico_ler on public.historico for select to authenticated
  using (hospital_id = meu_hospital() and (eh_coordenador()
         or de_medico_id = auth.uid() or para_medico_id = auth.uid() or feito_por = auth.uid()));
drop policy if exists historico_coord on public.historico;
create policy historico_coord on public.historico for insert to authenticated
  with check (hospital_id = meu_hospital() and eh_coordenador());

-- ---------- 6. AÇÕES DO APP (as regras ficam aqui, no servidor) ----------
create or replace function public._executar(p_sol uuid, p_por uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s solicitacoes; pl plantoes; pc plantoes;
begin
  select * into s from solicitacoes where id = p_sol for update;
  select * into pl from plantoes where id = s.plantao_id for update;
  if pl.inicio <= now() then raise exception 'O plantão já começou; este pedido não vale mais.'; end if;
  if not (s.tipo = 'anuncio' and pl.medico_id is null) and pl.medico_id is distinct from s.solicitante_id then
    raise exception 'O plantão mudou de dono desde o pedido.'; end if;
  if s.destinatario_id is null then raise exception 'Falta definir quem assume o plantão.'; end if;
  if s.tipo = 'troca' then
    select * into pc from plantoes where id = s.plantao_contra_id for update;
    if pc.medico_id is distinct from s.destinatario_id or pc.inicio <= now() then
      raise exception 'O plantão do colega mudou desde o pedido.'; end if;
    if _conflito(s.destinatario_id, pl.inicio, pl.fim, array[pc.id]) or _conflito(s.solicitante_id, pc.inicio, pc.fim, array[pl.id]) then
      raise exception 'Conflito de horário: alguém já tem plantão nesse período.'; end if;
    update plantoes set medico_id = s.destinatario_id, status = 'designado' where id = pl.id;
    update plantoes set medico_id = s.solicitante_id, status = 'designado' where id = pc.id;
    insert into historico (hospital_id, tipo, plantao_id, solicitacao_id, de_medico_id, para_medico_id, setor_id, inicio, fim, feito_por)
    values (s.hospital_id, 'troca', pl.id, s.id, s.solicitante_id, s.destinatario_id, pl.setor_id, pl.inicio, pl.fim, p_por),
           (s.hospital_id, 'troca', pc.id, s.id, s.destinatario_id, s.solicitante_id, pc.setor_id, pc.inicio, pc.fim, p_por);
  else
    if _conflito(s.destinatario_id, pl.inicio, pl.fim) then raise exception 'Quem vai assumir já tem plantão nesse horário.'; end if;
    update plantoes set medico_id = s.destinatario_id, status = 'designado' where id = pl.id;
    insert into historico (hospital_id, tipo, plantao_id, solicitacao_id, de_medico_id, para_medico_id, setor_id, inicio, fim, feito_por)
    values (s.hospital_id, s.tipo, pl.id, s.id, pl.medico_id, s.destinatario_id, pl.setor_id, pl.inicio, pl.fim, p_por);
  end if;
  update solicitacoes set status = 'concluida', concluido_em = now(), decidido_por = coalesce(decidido_por, p_por) where id = s.id;
  update solicitacoes set status = 'cancelada', motivo = 'O plantão foi movimentado por outro pedido.'
   where id <> s.id and status in ('pendente','aguardando_coordenador')
     and (plantao_id in (pl.id, pc.id) or plantao_contra_id in (pl.id, pc.id));
end $$;

create or replace function public.criar_solicitacao(p_tipo text, p_plantao uuid, p_destinatario uuid default null,
  p_plantao_contra uuid default null, p_mensagem text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare eu perfis := _eu(); pl plantoes; pc plantoes; novo uuid;
begin
  if p_tipo not in ('troca','passagem','anuncio') then raise exception 'Tipo de pedido inválido.'; end if;
  select * into pl from plantoes where id = p_plantao and hospital_id = eu.hospital_id for update;
  if pl.id is null then raise exception 'Plantão não encontrado.'; end if;
  if pl.inicio <= now() then raise exception 'Esse plantão já começou.'; end if;
  if pl.medico_id is null then
    if not (p_tipo = 'anuncio' and eu.papel = 'coordenador') then raise exception 'Plantão vago: só a coordenação pode anunciar.'; end if;
  elsif pl.medico_id <> eu.id then raise exception 'Este plantão não é seu.';
  end if;
  if p_tipo in ('troca','passagem') then
    if p_destinatario is null or p_destinatario = eu.id then raise exception 'Escolha um colega.'; end if;
    if not _apto(p_destinatario, pl.setor_id) then raise exception 'O colega não está habilitado neste setor.'; end if;
  end if;
  if p_tipo = 'troca' then
    select * into pc from plantoes where id = p_plantao_contra and hospital_id = eu.hospital_id;
    if pc.id is null or pc.medico_id is distinct from p_destinatario then raise exception 'Escolha um plantão do colega para trocar.'; end if;
    if pc.inicio <= now() then raise exception 'O plantão do colega já começou.'; end if;
    if not _apto(eu.id, pc.setor_id) then raise exception 'Você não está habilitado no setor do plantão do colega.'; end if;
    if _conflito(p_destinatario, pl.inicio, pl.fim, array[pc.id]) then raise exception 'O colega já tem plantão no seu horário.'; end if;
    if _conflito(eu.id, pc.inicio, pc.fim, array[pl.id]) then raise exception 'Você já tem plantão no horário do colega.'; end if;
  elsif p_tipo = 'passagem' then
    if _conflito(p_destinatario, pl.inicio, pl.fim) then raise exception 'O colega já tem plantão nesse horário.'; end if;
  end if;
  begin
    insert into solicitacoes (hospital_id, tipo, plantao_id, plantao_contra_id, solicitante_id, destinatario_id, mensagem)
    values (eu.hospital_id, p_tipo, pl.id, pc.id, eu.id,
            case when p_tipo = 'anuncio' then null else p_destinatario end, nullif(trim(p_mensagem), ''))
    returning id into novo;
  exception when unique_violation then
    raise exception 'Já existe um pedido em andamento para este plantão.';
  end;
  if p_tipo = 'anuncio' then update plantoes set status = 'anunciado' where id = pl.id; end if;
  return novo;
end $$;

create or replace function public.responder_solicitacao(p_solicitacao uuid, p_aceitar boolean, p_motivo text default null)
returns text language plpgsql security definer set search_path = public as $$
declare eu perfis := _eu(); s solicitacoes;
begin
  select * into s from solicitacoes where id = p_solicitacao and hospital_id = eu.hospital_id for update;
  if s.id is null or s.tipo = 'anuncio' or s.destinatario_id is distinct from eu.id then raise exception 'Pedido não encontrado.'; end if;
  if s.status <> 'pendente' then raise exception 'Este pedido já foi respondido.'; end if;
  if not p_aceitar then
    update solicitacoes set status = 'recusada', motivo = nullif(trim(p_motivo), ''), decidido_por = eu.id where id = s.id;
    return 'recusada';
  end if;
  update solicitacoes set aceito_em = now() where id = s.id;
  if _exige_aprovacao(s.plantao_id) or (s.plantao_contra_id is not null and _exige_aprovacao(s.plantao_contra_id)) then
    update solicitacoes set status = 'aguardando_coordenador' where id = s.id;
    return 'aguardando_coordenador';
  end if;
  perform _executar(s.id, eu.id);
  return 'concluida';
end $$;

create or replace function public.aprovar_solicitacao(p_solicitacao uuid, p_aprovar boolean, p_motivo text default null)
returns text language plpgsql security definer set search_path = public as $$
declare eu perfis := _eu(); s solicitacoes;
begin
  if eu.papel <> 'coordenador' then raise exception 'Só a coordenação aprova pedidos.'; end if;
  select * into s from solicitacoes where id = p_solicitacao and hospital_id = eu.hospital_id for update;
  if s.id is null or s.status <> 'aguardando_coordenador' then raise exception 'Não há nada para aprovar neste pedido.'; end if;
  if not p_aprovar then
    update solicitacoes set status = 'recusada', decidido_por = eu.id,
      motivo = coalesce(nullif(trim(p_motivo), ''), 'Recusado pela coordenação.') where id = s.id;
    update plantoes set status = case when medico_id is null then 'vago' else 'designado' end
     where id = s.plantao_id and status = 'anunciado';
    return 'recusada';
  end if;
  update solicitacoes set decidido_por = eu.id where id = s.id;
  perform _executar(s.id, eu.id);
  return 'concluida';
end $$;

create or replace function public.candidatar(p_solicitacao uuid, p_entrar boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare eu perfis := _eu(); s solicitacoes; pl plantoes;
begin
  select * into s from solicitacoes where id = p_solicitacao and hospital_id = eu.hospital_id;
  if s.id is null or s.tipo <> 'anuncio' or s.status <> 'pendente' then raise exception 'Este anúncio não está mais disponível.'; end if;
  if not p_entrar then
    update candidaturas set status = 'cancelada' where solicitacao_id = s.id and medico_id = eu.id and status = 'ativa';
    return;
  end if;
  if s.solicitante_id = eu.id then raise exception 'O anúncio é seu.'; end if;
  select * into pl from plantoes where id = s.plantao_id;
  if pl.medico_id = eu.id then raise exception 'O plantão já é seu.'; end if;
  if not _apto(eu.id, pl.setor_id) then raise exception 'Você não está habilitado neste setor.'; end if;
  if _conflito(eu.id, pl.inicio, pl.fim) then raise exception 'Você já tem plantão nesse horário.'; end if;
  insert into candidaturas (hospital_id, solicitacao_id, medico_id) values (eu.hospital_id, s.id, eu.id)
  on conflict (solicitacao_id, medico_id) do update set status = 'ativa', criado_em = now();
end $$;

create or replace function public.escolher_candidato(p_solicitacao uuid, p_medico uuid)
returns text language plpgsql security definer set search_path = public as $$
declare eu perfis := _eu(); s solicitacoes;
begin
  select * into s from solicitacoes where id = p_solicitacao and hospital_id = eu.hospital_id for update;
  if s.id is null or s.tipo <> 'anuncio' or s.status <> 'pendente' then raise exception 'Este anúncio não está mais disponível.'; end if;
  if s.solicitante_id <> eu.id and eu.papel <> 'coordenador' then raise exception 'Só quem anunciou ou a coordenação escolhe o candidato.'; end if;
  if not exists (select 1 from candidaturas where solicitacao_id = s.id and medico_id = p_medico and status = 'ativa') then
    raise exception 'Esse candidato não está mais disponível.'; end if;
  update solicitacoes set destinatario_id = p_medico, aceito_em = now() where id = s.id;
  update candidaturas set status = case when medico_id = p_medico then 'escolhida' else 'nao_escolhida' end
   where solicitacao_id = s.id and status = 'ativa';
  if _exige_aprovacao(s.plantao_id) and eu.papel <> 'coordenador' then
    update solicitacoes set status = 'aguardando_coordenador' where id = s.id;
    return 'aguardando_coordenador';
  end if;
  update solicitacoes set decidido_por = eu.id where id = s.id;
  perform _executar(s.id, eu.id);
  return 'concluida';
end $$;

create or replace function public.cancelar_solicitacao(p_solicitacao uuid)
returns void language plpgsql security definer set search_path = public as $$
declare eu perfis := _eu(); s solicitacoes;
begin
  select * into s from solicitacoes where id = p_solicitacao and hospital_id = eu.hospital_id for update;
  if s.id is null or (s.solicitante_id <> eu.id and eu.papel <> 'coordenador') then raise exception 'Pedido não encontrado.'; end if;
  if s.status not in ('pendente','aguardando_coordenador') then raise exception 'Este pedido já foi encerrado.'; end if;
  update solicitacoes set status = 'cancelada', decidido_por = eu.id where id = s.id;
  update plantoes set status = case when medico_id is null then 'vago' else 'designado' end
   where id = s.plantao_id and status = 'anunciado';
  update candidaturas set status = 'cancelada' where solicitacao_id = s.id and status = 'ativa';
end $$;

create or replace function public.dividir_plantao(p_plantao uuid, p_ponto timestamptz)
returns uuid language plpgsql security definer set search_path = public as $$
declare eu perfis := _eu(); pl plantoes; st setores; novo uuid; v1 numeric; v2 numeric;
begin
  select * into pl from plantoes where id = p_plantao and hospital_id = eu.hospital_id for update;
  if pl.id is null then raise exception 'Plantão não encontrado.'; end if;
  if pl.medico_id is distinct from eu.id and eu.papel <> 'coordenador' then raise exception 'Este plantão não é seu.'; end if;
  select * into st from setores where id = pl.setor_id;
  if not st.permite_divisao and eu.papel <> 'coordenador' then raise exception 'A divisão não é permitida neste setor.'; end if;
  if pl.inicio <= now() and eu.papel <> 'coordenador' then raise exception 'Esse plantão já começou.'; end if;
  if exists (select 1 from solicitacoes where status in ('pendente','aguardando_coordenador')
             and (plantao_id = pl.id or plantao_contra_id = pl.id)) then
    raise exception 'Cancele o pedido em andamento antes de dividir.'; end if;
  if p_ponto < pl.inicio + interval '1 hour' or p_ponto > pl.fim - interval '1 hour' then
    raise exception 'Cada parte precisa ter pelo menos 1 hora.'; end if;
  if pl.valor is not null then
    v1 := round(pl.valor * extract(epoch from (p_ponto - pl.inicio)) / extract(epoch from (pl.fim - pl.inicio)), 2);
    v2 := pl.valor - v1;
  end if;
  update plantoes set fim = p_ponto, valor = v1 where id = pl.id;
  insert into plantoes (hospital_id, setor_id, medico_id, inicio, fim, tipo, valor, status, origem_id, observacao)
  values (pl.hospital_id, pl.setor_id, pl.medico_id, p_ponto, pl.fim, pl.tipo, v2,
          case when pl.medico_id is null then 'vago' else 'designado' end, pl.id, pl.observacao)
  returning id into novo;
  insert into historico (hospital_id, tipo, plantao_id, de_medico_id, para_medico_id, setor_id, inicio, fim, detalhes, feito_por)
  values (pl.hospital_id, 'divisao', pl.id, pl.medico_id, pl.medico_id, pl.setor_id, pl.inicio, pl.fim,
          'Dividido às ' || to_char(p_ponto at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), eu.id);
  return novo;
end $$;

create or replace function public.registrar_presenca(p_plantao uuid, p_acao text)
returns void language plpgsql security definer set search_path = public as $$
declare eu perfis := _eu(); pl plantoes;
begin
  select * into pl from plantoes where id = p_plantao and medico_id = eu.id for update;
  if pl.id is null then raise exception 'Plantão não encontrado.'; end if;
  if p_acao = 'entrada' then
    if now() < pl.inicio - interval '2 hours' or now() > pl.fim then
      raise exception 'A entrada pode ser registrada de 2h antes do início até o fim do plantão.'; end if;
    update plantoes set checkin_em = now() where id = pl.id and checkin_em is null;
  else
    if pl.checkin_em is null then raise exception 'Registre a entrada primeiro.'; end if;
    update plantoes set checkout_em = now() where id = pl.id and checkout_em is null;
  end if;
end $$;

create or replace function public.atualizar_meu_perfil(p_nome text, p_crm text, p_uf text,
  p_especialidade text default null, p_telefone text default null)
returns void language plpgsql security definer set search_path = public as $$
declare eu perfis := _eu();
begin
  if coalesce(trim(p_nome), '') = '' or coalesce(trim(p_crm), '') = '' then raise exception 'Preencha nome completo e CRM.'; end if;
  update perfis set nome = trim(p_nome), crm = trim(p_crm), uf_crm = upper(trim(p_uf)),
    especialidade = nullif(trim(p_especialidade), ''), telefone = nullif(trim(p_telefone), ''),
    cadastro_completo = true, aceite_lgpd_em = coalesce(aceite_lgpd_em, now())
  where id = eu.id;
end $$;

-- a coordenação define uma senha provisória (não depende de e-mail)
create or replace function public.redefinir_senha(p_medico uuid, p_senha text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare eu perfis := _eu();
begin
  if eu.papel <> 'coordenador' then raise exception 'Só a coordenação redefine senhas.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if not exists (select 1 from perfis where id = p_medico and hospital_id = eu.hospital_id) then raise exception 'Médico não encontrado.'; end if;
  update auth.users set encrypted_password = crypt(p_senha, gen_salt('bf')), updated_at = now() where id = p_medico;
end $$;

-- ---------- 7. PERMISSÕES E TEMPO REAL ----------
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
-- a função interna que efetiva a troca só pode ser chamada pelas outras funções (nunca direto pelo app)
revoke execute on function public._executar(uuid, uuid) from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['plantoes','solicitacoes','candidaturas','perfis','setores'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then null;  -- já estava no tempo real
    end;
  end loop;
end $$;

-- Pronto! Agora crie os usuários em Authentication > Users > Add user > Create new user.
-- O PRIMEIRO usuário criado vira coordenador automaticamente.
