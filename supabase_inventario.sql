-- =====================================================================
--  SISTEMA DE INVENTÁRIO - ESTOQUE DE AMOSTRA
--  Script do banco: Supabase > SQL Editor > New query > colar tudo > Run
--  Pode rodar mais de uma vez sem problema.
--  Todas as tabelas começam com "inv_" para não misturar com outros painéis.
--
--  Perfis:
--    admin    = vê tudo: base de dados, acompanhamento, confronto,
--               recontagens, exportação e usuários
--    contador = só lança contagens (SKU, lote, validade/fabricação, quantidade).
--               Não vê quantidade do sistema, contagens de outros nem relatório.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. TABELAS
-- ---------------------------------------------------------------------
create table if not exists public.inv_perfis (
  id           uuid primary key references auth.users(id) on delete cascade,
  nome         text not null,
  login        text not null,
  email        text not null,
  perfil       text not null default 'contador',
  ativo        boolean not null default true,
  criado_em    timestamptz not null default now()
);
alter table public.inv_perfis drop constraint if exists inv_perfis_perfil_check;
alter table public.inv_perfis add constraint inv_perfis_perfil_check check (perfil in ('admin','contador'));
create unique index if not exists inv_perfis_login_idx on public.inv_perfis(lower(login));

-- BASE DE DADOS: relatório de saldo do sistema (armazém 11 – Amostras).
-- É a referência atual; cada inventário aberto guarda uma cópia dela como histórico.
create table if not exists public.inv_base (
  id             bigint generated always as identity primary key,
  codigo         text not null,
  descricao      text,
  lote           text,
  armazem        text,
  armazem_nome   text,
  saldo          numeric not null default 0,
  empenho        numeric not null default 0,
  data_ref       date,
  validade       date,
  fabricacao     date,
  origem         text,
  carregado_em   timestamptz not null default now(),
  carregado_por  text
);

alter table public.inv_base add column if not exists fabricacao date;

-- Cadastro de descrições (o relatório de Saldos por Lote não traz a descrição)
create table if not exists public.inv_produtos (
  codigo         text primary key,          -- SKU em maiúsculas
  descricao      text not null,
  atualizado_em  timestamptz not null default now()
);

-- Inventário (rodada = contagem liberada no momento: 1ª, 2ª, 3ª ou 4ª)
create table if not exists public.inv_inventarios (
  id             bigint generated always as identity primary key,
  nome           text not null,
  data_contagem  date not null default current_date,
  local          text default 'GERAL',
  armazem        text default 'GERAL',
  rua            text default 'GERAL',
  observacao     text,
  rodada         int not null default 1,
  status         text not null default 'aberto' check (status in ('aberto','encerrado')),
  criado_por     text,
  criado_em      timestamptz not null default now(),
  encerrado_em   timestamptz,
  encerrado_por  text
);
alter table public.inv_inventarios add column if not exists rodada int not null default 1;
alter table public.inv_inventarios add column if not exists tipo text not null default 'geral';   -- geral | parcial (itens selecionados)

-- Relatório de itens do sistema (1 linha por SKU + lote) e o resultado das contagens
create table if not exists public.inv_itens (
  id             bigint generated always as identity primary key,
  inventario_id  bigint not null references public.inv_inventarios(id) on delete cascade,
  ordem          int,
  empresa        text,
  armazem        text,
  local          text,
  codigo         text not null,
  descricao      text,
  lote           text,
  validade       date,
  fabricacao     date,
  data_ref       date,
  sistema        numeric not null default 0,
  extra          boolean not null default false,   -- true = não estava no relatório (sobra)
  c1 numeric, c1_por text, c1_em timestamptz,
  c2 numeric, c2_por text, c2_em timestamptz,
  c3 numeric, c3_por text, c3_em timestamptz,
  c4 numeric, c4_por text, c4_em timestamptz,
  transf_local   text,
  comentario     text,
  atualizado_em  timestamptz not null default now()
);
alter table public.inv_itens add column if not exists extra boolean not null default false;
alter table public.inv_itens add column if not exists data_ref date;
alter table public.inv_itens add column if not exists fabricacao date;
alter table public.inv_itens add column if not exists reaberto_rodada int;   -- administrador reabriu a contagem do item nesta rodada
create index if not exists inv_itens_inv_idx on public.inv_itens(inventario_id);
create index if not exists inv_itens_cod_idx on public.inv_itens(inventario_id, upper(trim(codigo)));

-- Cada lançamento feito por quem conta
create table if not exists public.inv_lancamentos (
  id             bigint generated always as identity primary key,
  inventario_id  bigint not null references public.inv_inventarios(id) on delete cascade,
  item_id        bigint references public.inv_itens(id) on delete set null,
  rodada         int not null,
  codigo         text not null,
  descricao      text,
  lote           text,
  tipo_data      text check (tipo_data in ('V','F')),   -- V = validade, F = fabricação
  data           date,
  quantidade     numeric not null,
  por            text,
  por_id         uuid,
  em             timestamptz not null default now()
);
alter table public.inv_lancamentos add column if not exists cancelado boolean not null default false;
alter table public.inv_lancamentos add column if not exists cancelado_por text;
alter table public.inv_lancamentos add column if not exists cancelado_em timestamptz;
create index if not exists inv_lanc_inv_idx on public.inv_lancamentos(inventario_id);
create index if not exists inv_lanc_item_idx on public.inv_lancamentos(item_id);

drop table if exists public.inv_sobras;

-- ---------------------------------------------------------------------
-- 2. FUNÇÕES
-- ---------------------------------------------------------------------
create or replace function public.inv_perfil_atual()
returns text language sql stable security definer set search_path = public as $$
  select perfil from public.inv_perfis where id = auth.uid() and ativo
$$;

-- Próxima contagem necessária (regra da coluna COMPARATIVO da planilha). 0 = concluído
create or replace function public.inv_proxima_rodada(
  p_transf text, p_sis numeric, p_c1 numeric, p_c2 numeric, p_c3 numeric, p_c4 numeric)
returns int language sql immutable as $$
  select case
    when coalesce(trim(p_transf),'') <> '' then 0
    when p_c1 is null then 1
    when p_c1 = p_sis then 0
    when p_c2 is null then 2
    when p_c2 = p_c1 then 0
    when p_c3 is null then 3
    when p_c3 = p_c2 then 0
    when p_c4 is null then 4
    else 0
  end
$$;

-- O item faz parte da contagem k? (1ª = todos; 2ª/3ª/4ª = só quem divergiu nas anteriores
-- ou que o administrador reabriu nesta contagem)
drop function if exists public.inv_precisa_rodada(text,numeric,numeric,numeric,numeric,int);
create or replace function public.inv_precisa_rodada(
  p_transf text, p_sis numeric, p_c1 numeric, p_c2 numeric, p_c3 numeric, p_k int, p_reab int)
returns boolean language sql immutable as $$
  select case
    when coalesce(trim(p_transf),'') <> '' then false
    when p_k = 1 then true
    when p_reab = p_k then true
    else public.inv_proxima_rodada(p_transf, p_sis, p_c1,
           case when p_k > 2 then p_c2 end, case when p_k > 3 then p_c3 end, null) = p_k
  end
$$;

-- Catálogo de SKUs do inventário (só código e descrição) para puxar a descrição
create or replace function public.inv_catalogo(p_inv bigint)
returns table (codigo text, descricao text)
language plpgsql stable security definer set search_path = public as $$
begin
  if public.inv_perfil_atual() is null then raise exception 'Sem acesso.'; end if;
  return query
    select distinct on (upper(trim(i.codigo))) trim(i.codigo), i.descricao
      from public.inv_itens i
     where i.inventario_id = p_inv and not i.extra
     order by upper(trim(i.codigo)), i.id;
end $$;

-- Itens da recontagem atual (sem quantidades) — para mostrar a quem conta
create or replace function public.inv_lista_recontagem(p_inv bigint)
returns table (id bigint, codigo text, descricao text, lote text, lancado boolean)
language plpgsql stable security definer set search_path = public as $$
declare k int;
begin
  if public.inv_perfil_atual() is null then raise exception 'Sem acesso.'; end if;
  select v.rodada into k from public.inv_inventarios v where v.id = p_inv;
  if k is null or k = 1 then return; end if;
  return query
    select i.id, i.codigo, i.descricao, i.lote,
           (case k when 2 then i.c2 when 3 then i.c3 else i.c4 end) is not null
      from public.inv_itens i
     where i.inventario_id = p_inv
       and public.inv_precisa_rodada(i.transf_local, i.sistema, i.c1, i.c2, i.c3, k, i.reaberto_rodada)
     order by i.codigo, i.lote;
end $$;

-- Andamento da contagem atual (só totais, sem quantidades) — usado no Início de quem conta
create or replace function public.inv_progresso(p_inv bigint)
returns json language plpgsql stable security definer set search_path = public as $$
declare k int; v_alvo int; v_feitos int; v_total int;
begin
  if public.inv_perfil_atual() is null then raise exception 'Sem acesso.'; end if;
  select v.rodada into k from public.inv_inventarios v where v.id = p_inv;
  select count(*) filter (where public.inv_precisa_rodada(i.transf_local, i.sistema, i.c1, i.c2, i.c3, k, i.reaberto_rodada)),
         count(*) filter (where public.inv_precisa_rodada(i.transf_local, i.sistema, i.c1, i.c2, i.c3, k, i.reaberto_rodada)
                            and (case k when 1 then i.c1 when 2 then i.c2 when 3 then i.c3 else i.c4 end) is not null),
         count(*) filter (where not i.extra)
    into v_alvo, v_feitos, v_total
    from public.inv_itens i where i.inventario_id = p_inv;
  return json_build_object('rodada', k, 'alvo', v_alvo, 'feitos', v_feitos, 'total', v_total);
end $$;

-- LANÇAR CONTAGEM (SKU + lote). Soma na contagem da rodada atual.
-- Se o SKU/lote não estiver no relatório, cria a linha como item não listado (sistema = 0).
create or replace function public.inv_lancar(
  p_inv bigint, p_codigo text, p_lote text, p_tipo_data text, p_data date,
  p_qtd numeric, p_descricao text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_nome text; v_inv public.inv_inventarios; k int;
  it public.inv_itens; v_cod text := upper(trim(coalesce(p_codigo,'')));
  v_lote text := upper(trim(coalesce(p_lote,''))); v_desc text; v_extra boolean := false; n int;
begin
  select nome into v_nome from public.inv_perfis where id = auth.uid() and ativo;
  if v_nome is null then raise exception 'Sem permissão para lançar contagens.'; end if;
  if v_cod = '' then raise exception 'Informe o SKU.'; end if;
  if p_qtd is null or p_qtd < 0 then raise exception 'Quantidade inválida.'; end if;

  select * into v_inv from public.inv_inventarios where id = p_inv for update;
  if not found then raise exception 'Inventário não encontrado.'; end if;
  if v_inv.status <> 'aberto' then raise exception 'Este inventário está finalizado.'; end if;
  k := v_inv.rodada;

  -- 1) SKU + lote exatos
  select * into it from public.inv_itens
   where inventario_id = p_inv and upper(trim(codigo)) = v_cod and upper(trim(coalesce(lote,''))) = v_lote
   order by extra, id limit 1 for update;
  -- 2) lote dentro de uma linha agrupada ("L1 / L2")
  if not found and v_lote <> '' then
    select * into it from public.inv_itens
     where inventario_id = p_inv and upper(trim(codigo)) = v_cod
       and v_lote = any (select upper(trim(x)) from unnest(string_to_array(coalesce(lote,''), '/')) x)
     order by extra, id limit 1 for update;
  end if;
  -- 3) SKU com uma única linha sem lote
  if not found then
    select count(*) into n from public.inv_itens where inventario_id = p_inv and upper(trim(codigo)) = v_cod;
    if n = 1 then
      select * into it from public.inv_itens
       where inventario_id = p_inv and upper(trim(codigo)) = v_cod and coalesce(trim(lote),'') = '' for update;
    end if;
  end if;

  -- inventário parcial: só os SKUs selecionados
  if it.id is null and v_inv.tipo = 'parcial'
     and not exists (select 1 from public.inv_itens where inventario_id = p_inv and upper(trim(codigo)) = v_cod) then
    raise exception 'Este SKU não faz parte deste inventário.';
  end if;

  if it.id is not null then
    if not public.inv_precisa_rodada(it.transf_local, it.sistema, it.c1, it.c2, it.c3, k, it.reaberto_rodada) then
      raise exception 'Este SKU/lote não está na lista da %ª contagem. Fale com o administrador.', k;
    end if;
    if k = 1 then
      update public.inv_itens set c1 = coalesce(c1,0) + p_qtd, c1_em = now(),
        c1_por = case when c1_por is null then v_nome when position(v_nome in c1_por) > 0 then c1_por else c1_por || ', ' || v_nome end
       where id = it.id;
    elsif k = 2 then
      update public.inv_itens set c2 = coalesce(c2,0) + p_qtd, c2_em = now(),
        c2_por = case when c2_por is null then v_nome when position(v_nome in c2_por) > 0 then c2_por else c2_por || ', ' || v_nome end
       where id = it.id;
    elsif k = 3 then
      update public.inv_itens set c3 = coalesce(c3,0) + p_qtd, c3_em = now(),
        c3_por = case when c3_por is null then v_nome when position(v_nome in c3_por) > 0 then c3_por else c3_por || ', ' || v_nome end
       where id = it.id;
    else
      update public.inv_itens set c4 = coalesce(c4,0) + p_qtd, c4_em = now(),
        c4_por = case when c4_por is null then v_nome when position(v_nome in c4_por) > 0 then c4_por else c4_por || ', ' || v_nome end
       where id = it.id;
    end if;
    update public.inv_itens set atualizado_em = now() where id = it.id;
    v_desc := it.descricao;
  else
    -- item não listado: entra com sistema 0
    v_extra := true;
    select descricao into v_desc from public.inv_itens
     where inventario_id = p_inv and upper(trim(codigo)) = v_cod and descricao is not null limit 1;
    if v_desc is null then select descricao into v_desc from public.inv_produtos where codigo = v_cod; end if;
    v_desc := coalesce(v_desc, nullif(trim(p_descricao),''));
    insert into public.inv_itens (inventario_id, ordem, codigo, descricao, lote, validade, sistema, extra,
                                  c1, c1_por, c1_em, c2, c2_por, c2_em, c3, c3_por, c3_em, c4, c4_por, c4_em, comentario)
    values (p_inv, 999999, trim(p_codigo), v_desc, nullif(trim(p_lote),''),
            case when p_tipo_data = 'V' then p_data end, 0, true,
            case when k = 1 then p_qtd else 0 end, case when k = 1 then v_nome end, case when k = 1 then now() end,
            case when k = 2 then p_qtd when k > 2 then 0 end, case when k = 2 then v_nome end, case when k = 2 then now() end,
            case when k = 3 then p_qtd when k > 3 then 0 end, case when k = 3 then v_nome end, case when k = 3 then now() end,
            case when k = 4 then p_qtd end, case when k = 4 then v_nome end, case when k = 4 then now() end,
            'Item não listado no relatório')
    returning * into it;
  end if;

  insert into public.inv_lancamentos (inventario_id, item_id, rodada, codigo, descricao, lote, tipo_data, data, quantidade, por, por_id)
  values (p_inv, it.id, k, trim(p_codigo), v_desc, nullif(trim(p_lote),''), p_tipo_data, p_data, p_qtd, v_nome, auth.uid());

  return json_build_object('ok', true, 'rodada', k, 'extra', v_extra);
end $$;

-- Refaz a contagem de uma rodada do item a partir dos lançamentos válidos (não cancelados)
create or replace function public.inv_refazer_rodada_interno(p_item bigint, k int)
returns void language plpgsql security definer set search_path = public as $$
declare s numeric; q text; n int; ult timestamptz;
begin
  select sum(quantidade), string_agg(distinct por, ', '), count(*), max(em) into s, q, n, ult
    from public.inv_lancamentos where item_id = p_item and rodada = k and not cancelado;
  if    k = 1 then update public.inv_itens set c1 = s, c1_por = q, c1_em = ult where id = p_item;
  elsif k = 2 then update public.inv_itens set c2 = s, c2_por = q, c2_em = ult where id = p_item;
  elsif k = 3 then update public.inv_itens set c3 = s, c3_por = q, c3_em = ult where id = p_item;
  else             update public.inv_itens set c4 = s, c4_por = q, c4_em = ult where id = p_item;
  end if;
  update public.inv_itens set atualizado_em = now() where id = p_item;
end $$;
revoke all on function public.inv_refazer_rodada_interno(bigint,int) from public, anon, authenticated;

-- SÓ ADMINISTRADOR: cancela um lançamento (fica no histórico como cancelado) e refaz a soma do item
create or replace function public.inv_excluir_lancamento(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare l public.inv_lancamentos; v_inv public.inv_inventarios; v_nome text;
begin
  if public.inv_perfil_atual() is distinct from 'admin' then
    raise exception 'Somente o administrador pode excluir lançamentos.';
  end if;
  select * into l from public.inv_lancamentos where id = p_id;
  if not found or l.cancelado then raise exception 'Lançamento não encontrado.'; end if;
  select * into v_inv from public.inv_inventarios where id = l.inventario_id;
  if v_inv.status <> 'aberto' then raise exception 'Este inventário está finalizado. Reabra-o para ajustar.'; end if;
  select nome into v_nome from public.inv_perfis where id = auth.uid();
  update public.inv_lancamentos set cancelado = true, cancelado_por = v_nome, cancelado_em = now() where id = p_id;
  if l.item_id is not null then perform public.inv_refazer_rodada_interno(l.item_id, l.rodada); end if;
end $$;

-- SÓ ADMINISTRADOR: reabre a contagem do item na contagem atual
-- (cancela os lançamentos dele nesta contagem e o item volta para a lista de quem conta)
create or replace function public.inv_reabrir_item(p_item bigint)
returns void language plpgsql security definer set search_path = public as $$
declare it public.inv_itens; v_inv public.inv_inventarios; v_nome text; k int;
begin
  if public.inv_perfil_atual() is distinct from 'admin' then
    raise exception 'Somente o administrador pode reabrir a contagem de um item.';
  end if;
  select * into it from public.inv_itens where id = p_item for update;
  if not found then raise exception 'Item não encontrado.'; end if;
  select * into v_inv from public.inv_inventarios where id = it.inventario_id;
  if v_inv.status <> 'aberto' then raise exception 'Este inventário está finalizado. Reabra-o para ajustar.'; end if;
  k := v_inv.rodada;
  select nome into v_nome from public.inv_perfis where id = auth.uid();
  update public.inv_lancamentos set cancelado = true, cancelado_por = v_nome, cancelado_em = now()
   where item_id = p_item and rodada = k and not cancelado;
  if    k = 1 then update public.inv_itens set c1 = null, c1_por = null, c1_em = null where id = p_item;
  elsif k = 2 then update public.inv_itens set c2 = null, c2_por = null, c2_em = null where id = p_item;
  elsif k = 3 then update public.inv_itens set c3 = null, c3_por = null, c3_em = null where id = p_item;
  else             update public.inv_itens set c4 = null, c4_por = null, c4_em = null where id = p_item;
  end if;
  update public.inv_itens set reaberto_rodada = k, atualizado_em = now(),
    comentario = coalesce(nullif(comentario,'') || ' | ', '') || 'Contagem reaberta na ' || k || 'ª por ' || coalesce(v_nome,'administrador')
   where id = p_item;
end $$;

-- Fecha a contagem atual. Na 1ª contagem, o que ninguém lançou fica com 0 (não encontrado).
-- Nas recontagens, o que não foi recontado fica com a última contagem (sem recontagem).
create or replace function public.inv_fechar_rodada_interno(p_inv bigint, k int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if k <> 1 then return; end if;
  update public.inv_itens i set
    c1 = case when k = 1 and i.c1 is null then 0 else i.c1 end,
    c1_por = case when k = 1 and i.c1 is null then 'NÃO ENCONTRADO' else i.c1_por end,
    c2 = case when k = 2 and i.c2 is null then 0 else i.c2 end,
    c2_por = case when k = 2 and i.c2 is null then 'NÃO ENCONTRADO' else i.c2_por end,
    c3 = case when k = 3 and i.c3 is null then 0 else i.c3 end,
    c3_por = case when k = 3 and i.c3 is null then 'NÃO ENCONTRADO' else i.c3_por end,
    c4 = case when k = 4 and i.c4 is null then 0 else i.c4 end,
    c4_por = case when k = 4 and i.c4 is null then 'NÃO ENCONTRADO' else i.c4_por end,
    atualizado_em = now()
  where i.inventario_id = p_inv
    and public.inv_precisa_rodada(i.transf_local, i.sistema, i.c1, i.c2, i.c3, k, i.reaberto_rodada)
    and (case k when 1 then i.c1 when 2 then i.c2 when 3 then i.c3 else i.c4 end) is null;
end $$;
revoke all on function public.inv_fechar_rodada_interno(bigint,int) from public, anon, authenticated;

-- Administrador: encerra a contagem atual e libera a próxima (só para os itens divergentes).
-- Devolve quantos itens vão para a próxima contagem (0 = nada a recontar).
create or replace function public.inv_avancar_rodada(p_inv bigint)
returns int language plpgsql security definer set search_path = public as $$
declare v_inv public.inv_inventarios; n int;
begin
  if public.inv_perfil_atual() is distinct from 'admin' then raise exception 'Apenas o administrador.'; end if;
  select * into v_inv from public.inv_inventarios where id = p_inv for update;
  if v_inv.status <> 'aberto' then raise exception 'Este inventário está finalizado.'; end if;
  if v_inv.rodada >= 4 then raise exception 'A 4ª contagem é a última. Finalize o inventário.'; end if;
  perform public.inv_fechar_rodada_interno(p_inv, v_inv.rodada);
  select count(*) into n from public.inv_itens i
   where i.inventario_id = p_inv and public.inv_precisa_rodada(i.transf_local, i.sistema, i.c1, i.c2, i.c3, v_inv.rodada + 1, i.reaberto_rodada);
  if n > 0 then update public.inv_inventarios set rodada = rodada + 1 where id = p_inv; end if;
  return n;
end $$;

-- Administrador: finaliza o inventário (o que faltou contar na rodada atual fica com 0)
create or replace function public.inv_finalizar(p_inv bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_inv public.inv_inventarios; v_nome text;
begin
  if public.inv_perfil_atual() is distinct from 'admin' then raise exception 'Apenas o administrador.'; end if;
  select * into v_inv from public.inv_inventarios where id = p_inv for update;
  if v_inv.status <> 'aberto' then return; end if;
  select nome into v_nome from public.inv_perfis where id = auth.uid();
  perform public.inv_fechar_rodada_interno(p_inv, v_inv.rodada);
  update public.inv_inventarios set status = 'encerrado', encerrado_em = now(), encerrado_por = v_nome where id = p_inv;
end $$;

-- Completa a descrição da base e dos inventários a partir do cadastro de descrições
create or replace function public.inv_aplicar_descricoes()
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.inv_perfil_atual() is distinct from 'admin' then raise exception 'Apenas o administrador.'; end if;
  update public.inv_base b set descricao = p.descricao
    from public.inv_produtos p where upper(trim(b.codigo)) = p.codigo and coalesce(b.descricao,'') = '';
  update public.inv_itens i set descricao = p.descricao
    from public.inv_produtos p where upper(trim(i.codigo)) = p.codigo and coalesce(i.descricao,'') = '';
  update public.inv_lancamentos l set descricao = p.descricao
    from public.inv_produtos p where upper(trim(l.codigo)) = p.codigo and coalesce(l.descricao,'') = '';
end $$;

-- Usuários (mesmo modelo do painel da Logística: cadastro direto, sem e-mail)
create or replace function public.inv_criar_usuario(p_login text, p_senha text, p_nome text, p_perfil text)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
declare uid uuid := gen_random_uuid(); lg text := lower(trim(p_login)); em text;
begin
  if public.inv_perfil_atual() is distinct from 'admin' then raise exception 'Apenas o administrador pode cadastrar usuários.'; end if;
  if p_perfil not in ('admin','contador') then raise exception 'Perfil inválido.'; end if;
  if coalesce(trim(p_nome),'') = '' or lg = '' then raise exception 'Informe o nome e o usuário.'; end if;
  if length(coalesce(p_senha,'')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  em := case when lg like '%@%' then lg else lg || '@inventario-labor.com.br' end;
  if exists (select 1 from auth.users where lower(email) = em)
     or exists (select 1 from public.inv_perfis where lower(login) = lg) then
    raise exception 'Esse usuário já existe.';
  end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change, email_change_token_new)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
          crypt(p_senha, gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('nome', p_nome),
          now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text,
          jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true),
          'email', now(), now(), now());
  insert into public.inv_perfis (id, nome, login, email, perfil, ativo)
  values (uid, trim(p_nome), lg, em, p_perfil, true);
  return uid;
end $$;

drop function if exists public.inv_resetar_senha(uuid);
create or replace function public.inv_resetar_senha(p_uid uuid, p_senha text)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if public.inv_perfil_atual() is distinct from 'admin' then raise exception 'Apenas o administrador pode trocar senhas.'; end if;
  if length(coalesce(p_senha,'')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  update auth.users set encrypted_password = crypt(p_senha, gen_salt('bf')), updated_at = now() where id = p_uid;
end $$;

create or replace function public.inv_apagar_usuario(p_uid uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if public.inv_perfil_atual() is distinct from 'admin' then raise exception 'Apenas o administrador pode apagar usuários.'; end if;
  if p_uid = auth.uid() then raise exception 'Você não pode apagar o seu próprio usuário.'; end if;
  delete from public.inv_perfis where id = p_uid;
  delete from auth.users where id = p_uid;
end $$;

-- limpeza de versões antigas deste script
drop function if exists public.inv_senha_trocada();
drop function if exists public.inv_registrar_contagem(bigint,int,numeric,text);
drop function if exists public.inv_lista_contagem(bigint);

do $$ declare f text; begin
  foreach f in array array[
    'inv_catalogo(bigint)','inv_lista_recontagem(bigint)','inv_progresso(bigint)',
    'inv_lancar(bigint,text,text,text,date,numeric,text)','inv_excluir_lancamento(bigint)','inv_reabrir_item(bigint)',
    'inv_avancar_rodada(bigint)','inv_finalizar(bigint)','inv_aplicar_descricoes()',
    'inv_criar_usuario(text,text,text,text)','inv_resetar_senha(uuid,text)','inv_apagar_usuario(uuid)','inv_perfil_atual()']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3. SEGURANÇA (RLS)
-- ---------------------------------------------------------------------
alter table public.inv_perfis      enable row level security;
alter table public.inv_inventarios enable row level security;
alter table public.inv_itens       enable row level security;
alter table public.inv_lancamentos enable row level security;
alter table public.inv_base        enable row level security;
alter table public.inv_produtos    enable row level security;

do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('inv_perfis','inv_inventarios','inv_itens','inv_lancamentos','inv_base','inv_produtos')
  loop execute format('drop policy %I on public.%I', r.policyname, r.tablename); end loop;
end $$;

create policy perfis_ler on public.inv_perfis for select to authenticated
  using (id = auth.uid() or public.inv_perfil_atual() = 'admin');
create policy perfis_admin on public.inv_perfis for all to authenticated
  using (public.inv_perfil_atual() = 'admin') with check (public.inv_perfil_atual() = 'admin');

create policy inv_ler on public.inv_inventarios for select to authenticated
  using (public.inv_perfil_atual() is not null);
create policy inv_admin on public.inv_inventarios for all to authenticated
  using (public.inv_perfil_atual() = 'admin') with check (public.inv_perfil_atual() = 'admin');

-- Itens (com quantidade do sistema): só administrador
create policy itens_admin on public.inv_itens for all to authenticated
  using (public.inv_perfil_atual() = 'admin') with check (public.inv_perfil_atual() = 'admin');

-- Base de dados: só administrador
create policy base_admin on public.inv_base for all to authenticated
  using (public.inv_perfil_atual() = 'admin') with check (public.inv_perfil_atual() = 'admin');

create policy produtos_admin on public.inv_produtos for all to authenticated
  using (public.inv_perfil_atual() = 'admin') with check (public.inv_perfil_atual() = 'admin');

-- Lançamentos: quem conta vê só os seus; administrador vê todos. Gravação só pelas funções.
create policy lanc_ler on public.inv_lancamentos for select to authenticated
  using (public.inv_perfil_atual() = 'admin' or por_id = auth.uid());

-- ---------------------------------------------------------------------
-- 4. TEMPO REAL (o acompanhamento do administrador atualiza sozinho)
-- ---------------------------------------------------------------------
do $$ begin
  begin alter publication supabase_realtime add table public.inv_itens;       exception when others then null; end;
  begin alter publication supabase_realtime add table public.inv_lancamentos; exception when others then null; end;
  begin alter publication supabase_realtime add table public.inv_inventarios; exception when others then null; end;
end $$;

-- ---------------------------------------------------------------------
-- 5. PRIMEIRO USUÁRIO (administrador de teste)
--    Usuário: nataly   Senha: 123456
--    Depois de entrar, troque a senha em "Alterar senha".
-- ---------------------------------------------------------------------
do $$
declare uid uuid; em text := 'nataly@inventario-labor.com.br';
begin
  select id into uid from auth.users where lower(email) = em;
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change, email_change_token_new)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
            extensions.crypt('123456', extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{"nome":"Nataly"}'::jsonb,
            now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text,
            jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true),
            'email', now(), now(), now());
  end if;
  insert into public.inv_perfis (id, nome, login, email, perfil, ativo)
  values (uid, 'Nataly', 'nataly', em, 'admin', true)
  on conflict (id) do update set perfil = 'admin', ativo = true;
end $$;
