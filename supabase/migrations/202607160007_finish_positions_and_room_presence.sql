-- Classificação completa e remoção de salas realmente vazias.

alter table public.rooms
  add column if not exists owner_present boolean not null default true;

alter table public.players
  add column if not exists finish_position smallint,
  add column if not exists finished_at timestamptz;

alter table public.players drop constraint if exists players_finish_position_check;
alter table public.players
  add constraint players_finish_position_check check (finish_position is null or finish_position > 0);

create unique index if not exists players_room_finish_position_key
  on public.players(room_id, finish_position) where finish_position is not null;

create or replace function public.next_player_id(p_room_id uuid, p_current_id uuid)
returns uuid language sql stable set search_path = '' as $$
  with ordered as (
    select id, row_number() over (order by joined_at, id) as position
    from public.players
    where room_id = p_room_id and finish_position is null
  ), current_position as (
    select position from ordered where id = p_current_id
  )
  select coalesce(
    (select id from ordered
      where position > coalesce((select position from current_position), 0)
      order by position limit 1),
    (select id from ordered order by position limit 1)
  );
$$;

create or replace function public.start_race(p_room_code text)
returns public.rooms
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_first_player uuid;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null then raise exception 'Sala não encontrada'; end if;
  if v_room.owner_id <> auth.uid() then raise exception 'Somente o dono pode iniciar'; end if;
  if (select count(*) from public.players where room_id = v_room.id) < 2 then
    raise exception 'São necessários pelo menos dois pilotos';
  end if;

  update public.players set score = 0, roll_count = 0,
    finish_position = null, finished_at = null where room_id = v_room.id;
  delete from public.claimed_gifts where room_id = v_room.id;
  select id into v_first_player from public.players
    where room_id = v_room.id order by joined_at, id limit 1;
  update public.rooms set status = 'racing', current_player_id = v_first_player,
    pending_item = null, last_event = null, winner_id = null, owner_present = true
    where id = v_room.id returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.roll_d20_core(p_room_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_player public.players;
  v_roll integer := floor(random() * 20 + 1);
  v_old_score integer;
  v_new_score integer;
  v_total integer;
  v_lap integer;
  v_marker integer;
  v_absolute integer;
  v_item text := null;
  v_damage integer;
  v_pending jsonb := null;
  v_event jsonb := null;
  v_position integer;
  v_next uuid;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null then raise exception 'Sala não encontrada'; end if;
  if v_room.status <> 'racing' then raise exception 'A corrida não está ativa'; end if;
  if v_room.pending_item is not null then raise exception 'Resolva o item pendente primeiro'; end if;
  select * into v_player from public.players where id = v_room.current_player_id for update;
  if v_player.id is null or v_player.finish_position is not null then raise exception 'Piloto inválido'; end if;
  if auth.uid() not in (v_player.owner_id, v_room.owner_id) then raise exception 'Não é a sua vez'; end if;

  v_old_score := v_player.score;
  v_new_score := v_old_score + v_roll;
  v_total := v_room.laps * 100;
  update public.players set score = v_new_score, roll_count = roll_count + 1 where id = v_player.id;

  while v_new_score < v_total and v_pending is null loop
    select route.lap, route.marker, route.absolute into v_lap, v_marker, v_absolute
    from (
      select lap_number::integer as lap, marker_value::integer as marker,
        ((lap_number - 1) * 100 + marker_value)::integer as absolute
      from generate_series(1, v_room.laps) as laps(lap_number)
      cross join unnest(array[25, 50, 75]) as markers(marker_value)
    ) route
    where route.absolute > v_old_score and route.absolute <= v_new_score
      and not exists (
        select 1 from public.claimed_gifts claimed
        where claimed.player_id = v_player.id
          and claimed.lap = route.lap and claimed.marker = route.marker
      )
    order by route.absolute limit 1;
    exit when not found;

    case floor(random() * 4)::integer
      when 0 then v_item := 'shell'; v_damage := 15;
      when 1 then v_item := 'banana'; v_damage := 8;
      when 2 then v_item := 'lightning'; v_damage := 20;
      else v_item := 'turbo'; v_damage := 0;
    end case;
    insert into public.claimed_gifts(room_id, player_id, lap, marker, item_type)
      values(v_room.id, v_player.id, v_lap, v_marker, v_item);
    if v_item = 'turbo' then
      v_new_score := v_new_score + 15;
      update public.players set score = v_new_score where id = v_player.id;
      v_event := jsonb_build_object('id', gen_random_uuid(), 'type', 'turbo',
        'source_id', v_player.id, 'target_id', null, 'boost', 15,
        'lap', v_lap, 'marker', v_marker, 'created_at', now());
    elsif exists (
      select 1 from public.players opponent
      where opponent.room_id = v_room.id
        and opponent.id <> v_player.id
        and opponent.finish_position is null
    ) then
      v_pending := jsonb_build_object('player_id', v_player.id, 'type', v_item,
        'damage', v_damage, 'lap', v_lap, 'marker', v_marker,
        'expires_at', now() + interval '1 minute');
    else
      v_event := jsonb_build_object('id', gen_random_uuid(), 'type', 'no_target',
        'item_type', v_item, 'source_id', v_player.id, 'damage', v_damage,
        'lap', v_lap, 'marker', v_marker, 'created_at', now());
    end if;
  end loop;

  if v_new_score >= v_total then
    select count(*) + 1 into v_position from public.players
      where room_id = v_room.id and finish_position is not null;
    update public.players set score = v_total, finish_position = v_position,
      finished_at = now() where id = v_player.id;
    v_event := jsonb_build_object('id', gen_random_uuid(), 'type', 'finish',
      'source_id', v_player.id, 'position', v_position, 'created_at', now());
    select public.next_player_id(v_room.id, v_player.id) into v_next;
    if v_next is null then
      update public.rooms set status = 'finished', current_player_id = null,
        pending_item = null, winner_id = (
          select id from public.players where room_id = v_room.id and finish_position = 1
        ), last_event = v_event where id = v_room.id;
    else
      update public.rooms set current_player_id = v_next, pending_item = null,
        winner_id = case when v_position = 1 then v_player.id else winner_id end,
        last_event = v_event where id = v_room.id;
    end if;
  elsif v_pending is not null then
    update public.rooms set pending_item = v_pending,
      last_event = coalesce(v_event, last_event) where id = v_room.id;
  else
    update public.rooms set current_player_id = public.next_player_id(v_room.id, v_player.id),
      last_event = coalesce(v_event, last_event) where id = v_room.id;
  end if;

  return jsonb_build_object('roll', v_roll, 'item', v_item,
    'pending_item', v_pending, 'event', v_event, 'player_id', v_player.id,
    'score', least(v_new_score, v_total), 'finish_position', v_position);
end;
$$;

create or replace function public.leave_room(p_room_code text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null then return false; end if;
  delete from public.players where room_id = v_room.id and owner_id = auth.uid();
  if v_room.owner_id = auth.uid() then
    update public.rooms set owner_present = false where id = v_room.id;
  end if;
  if not exists (select 1 from public.players where room_id = v_room.id)
    and not (select owner_present from public.rooms where id = v_room.id) then
    delete from public.rooms where id = v_room.id;
  end if;
  return true;
end;
$$;

revoke all on function public.leave_room(text) from public, anon;
grant execute on function public.leave_room(text) to authenticated;

create or replace function public.enter_room(p_room_code text)
returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update public.rooms set owner_present = true
    where code = upper(p_room_code) and owner_id = auth.uid();
  return found;
end;
$$;

revoke all on function public.enter_room(text) from public, anon;
grant execute on function public.enter_room(text) to authenticated;

create or replace function public.use_pending_item(p_room_code text, p_target_player_id uuid)
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
      current_player_id = public.next_player_id(v_room.id, v_source.id) where id = v_room.id;
    return jsonb_build_object('expired', true);
  end if;
  if auth.uid() not in (v_source.owner_id, v_room.owner_id) then
    raise exception 'Sem permissão para usar este item';
  end if;
  select * into v_target from public.players
    where id = p_target_player_id and room_id = v_room.id
      and finish_position is null for update;
  if v_target.id is null or v_target.id = v_source.id then raise exception 'Alvo inválido'; end if;
  v_damage := (v_room.pending_item->>'damage')::integer;
  v_event := jsonb_build_object('id', gen_random_uuid(),
    'type', v_room.pending_item->>'type', 'source_id', v_source.id,
    'target_id', v_target.id, 'damage', v_damage, 'created_at', now());
  update public.players set score = greatest(0, score - v_damage) where id = v_target.id;
  update public.rooms set pending_item = null,
    current_player_id = public.next_player_id(v_room.id, v_source.id),
    last_event = v_event where id = v_room.id;
  return jsonb_build_object('target_id', v_target.id, 'damage', v_damage, 'event', v_event);
end;
$$;

create or replace function public.delete_empty_room_after_player_leave()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.players where room_id = old.room_id)
    and exists (select 1 from public.rooms where id = old.room_id and owner_present = false) then
    delete from public.rooms where id = old.room_id;
  end if;
  return old;
end;
$$;

create or replace function public.repair_room_after_player_leave()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_next uuid;
begin
  select id into v_next from public.players
    where room_id = old.room_id and finish_position is null
    order by joined_at, id limit 1;
  update public.rooms
    set current_player_id = case when current_player_id is null then v_next else current_player_id end,
        pending_item = case
          when pending_item is not null
            and (pending_item->>'player_id')::uuid = old.id then null
          else pending_item
        end
    where id = old.room_id;
  return old;
end;
$$;
