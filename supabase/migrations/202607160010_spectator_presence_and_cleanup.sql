-- Espectadores sem corredor, presença online e correções de alvos.

create table if not exists public.room_presence (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  spectator_only boolean not null default false,
  last_seen_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

create index if not exists room_presence_last_seen_idx
  on public.room_presence(last_seen_at);

alter table public.room_presence enable row level security;

drop policy if exists "room presence is visible to authenticated users" on public.room_presence;
create policy "room presence is visible to authenticated users"
on public.room_presence for select to authenticated using (true);

drop policy if exists "authenticated users can create rooms" on public.rooms;
create policy "authenticated users can create rooms"
on public.rooms for insert to authenticated
with check (
  (select auth.uid()) = owner_id
  and (
    select count(*) from public.rooms recent
    where recent.owner_id = (select auth.uid())
      and recent.created_at >= now() - interval '10 minutes'
  ) < 3
);

drop function if exists public.enter_room(text);

create or replace function public.enter_room(
  p_room_code text,
  p_spectator_only boolean default false
)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_room_id uuid;
begin
  select id into v_room_id
  from public.rooms
  where code = upper(p_room_code);

  if v_room_id is null then return false; end if;

  insert into public.room_presence(room_id, user_id, spectator_only, last_seen_at)
  values(v_room_id, auth.uid(), p_spectator_only, now())
  on conflict (room_id, user_id) do update
    set spectator_only = excluded.spectator_only,
        last_seen_at = now();

  update public.rooms set owner_present = true
  where id = v_room_id and owner_id = auth.uid();

  return true;
end;
$$;

revoke all on function public.enter_room(text, boolean) from public, anon;
grant execute on function public.enter_room(text, boolean) to authenticated;

create or replace function public.heartbeat_room(p_room_code text)
returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update public.room_presence
  set last_seen_at = now()
  where room_id = (select id from public.rooms where code = upper(p_room_code))
    and user_id = auth.uid();
  return found;
end;
$$;

revoke all on function public.heartbeat_room(text) from public, anon;
grant execute on function public.heartbeat_room(text) to authenticated;

create or replace function public.leave_room(p_room_code text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
begin
  select * into v_room
  from public.rooms
  where code = upper(p_room_code)
  for update;

  if v_room.id is null then return false; end if;

  delete from public.room_presence
  where room_id = v_room.id and user_id = auth.uid();

  delete from public.players
  where room_id = v_room.id and owner_id = auth.uid();

  if v_room.owner_id = auth.uid() then
    update public.rooms set owner_present = false where id = v_room.id;
  end if;

  if not exists (
    select 1 from public.room_presence
    where room_id = v_room.id and last_seen_at >= now() - interval '2 minutes'
  ) then
    delete from public.rooms where id = v_room.id;
  end if;

  return true;
end;
$$;

revoke all on function public.leave_room(text) from public, anon;
grant execute on function public.leave_room(text) to authenticated;

create or replace function public.cleanup_abandoned_rooms()
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_deleted integer;
begin
  delete from public.room_presence
  where last_seen_at < now() - interval '2 minutes';

  delete from public.rooms room
  where not exists (
    select 1 from public.room_presence presence
    where presence.room_id = room.id
  )
  and room.updated_at < now() - interval '2 minutes';

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.cleanup_abandoned_rooms() from public, anon;
grant execute on function public.cleanup_abandoned_rooms() to authenticated;

-- Executada por clientes ativos; não depende de extensões opcionais do Supabase.
create or replace function public.heartbeat_and_cleanup(p_room_code text)
returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform public.cleanup_abandoned_rooms();
  return public.heartbeat_room(p_room_code);
end;
$$;

revoke all on function public.heartbeat_and_cleanup(text) from public, anon;
grant execute on function public.heartbeat_and_cleanup(text) to authenticated;

create or replace function public.use_pending_item(
  p_room_code text,
  p_target_player_id uuid
)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_source public.players;
  v_target public.players;
  v_damage integer;
  v_event jsonb;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.pending_item is null then raise exception 'Não há item pendente'; end if;

  select * into v_source from public.players
  where id = (v_room.pending_item->>'player_id')::uuid;

  if now() >= (v_room.pending_item->>'expires_at')::timestamptz then
    update public.rooms set pending_item = null,
      current_player_id = public.next_player_id(v_room.id, v_source.id)
    where id = v_room.id;
    return jsonb_build_object('expired', true);
  end if;

  if auth.uid() not in (v_source.owner_id, v_room.owner_id) then
    raise exception 'Sem permissão para usar este item';
  end if;

  select * into v_target from public.players
  where id = p_target_player_id
    and room_id = v_room.id
    and finish_position is null
    and is_spectator = false
  for update;

  if v_target.id is null or v_target.id = v_source.id then
    raise exception 'Alvo inválido';
  end if;

  v_damage := (v_room.pending_item->>'damage')::integer;
  v_event := jsonb_build_object(
    'id', gen_random_uuid(),
    'type', v_room.pending_item->>'type',
    'source_id', v_source.id,
    'target_id', v_target.id,
    'damage', v_damage,
    'created_at', now()
  );

  update public.players
  set score = greatest(0, score - v_damage)
  where id = v_target.id;

  update public.rooms
  set pending_item = null,
      current_player_id = public.next_player_id(v_room.id, v_source.id),
      last_event = v_event
  where id = v_room.id;

  return jsonb_build_object(
    'target_id', v_target.id,
    'damage', v_damage,
    'event', v_event
  );
end;
$$;

-- Corrige presentes criados quando só existem espectadores/quem já terminou.
create or replace function public.roll_d20_core(p_room_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_result jsonb;
  v_room public.rooms;
  v_player public.players;
  v_event jsonb;
  v_item text;
begin
  v_result := public.roll_d20_core_positions(p_room_code);
  v_item := v_result->>'item';

  select * into v_room from public.rooms
  where code = upper(p_room_code)
  for update;

  if v_result->'pending_item' <> 'null'::jsonb
    and not exists (
      select 1 from public.players opponent
      where opponent.room_id = v_room.id
        and opponent.id <> (v_result->>'player_id')::uuid
        and opponent.finish_position is null
        and opponent.is_spectator = false
    ) then
    select * into v_player from public.players
    where id = (v_result->>'player_id')::uuid;

    v_event := jsonb_build_object(
      'id', gen_random_uuid(),
      'type', 'no_target',
      'item_type', v_item,
      'source_id', v_player.id,
      'created_at', now()
    );

    update public.rooms
    set pending_item = null,
        current_player_id = public.next_player_id(v_room.id, v_player.id),
        last_event = v_event
    where id = v_room.id;

    return v_result || jsonb_build_object(
      'pending_item', null,
      'event', v_event
    );
  end if;

  if v_item in ('shell', 'banana', 'lightning')
    and v_result->'pending_item' = 'null'::jsonb
    and v_result->'event' = 'null'::jsonb then
    select * into v_player from public.players
    where id = (v_result->>'player_id')::uuid;

    if v_room.status = 'racing' and v_player.finish_position is null then
      v_event := jsonb_build_object(
        'id', gen_random_uuid(),
        'type', 'no_target',
        'item_type', v_item,
        'source_id', v_player.id,
        'created_at', now()
      );
      update public.rooms set last_event = v_event where id = v_room.id;
      v_result := v_result || jsonb_build_object('event', v_event);
    end if;
  end if;

  return v_result;
end;
$$;

revoke all on function public.roll_d20_core(text) from public, anon, authenticated;
