-- Turbo +10, sequência turbo/vitória e última rolagem pública.

alter table public.rooms add column if not exists last_roll jsonb;

create or replace function public.clear_last_roll_on_race_start()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status = 'racing' and old.status is distinct from new.status then
    new.last_roll = null;
  end if;
  return new;
end;
$$;

drop trigger if exists rooms_clear_last_roll_on_race_start on public.rooms;
create trigger rooms_clear_last_roll_on_race_start
before update of status on public.rooms
for each row execute function public.clear_last_roll_on_race_start();

create or replace function public.roll_d20_core_positions(p_room_code text)
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
  v_turbo_before_finish boolean := false;
  v_roll_event jsonb;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null then raise exception 'Sala não encontrada'; end if;
  if v_room.status <> 'racing' then raise exception 'A corrida não está ativa'; end if;
  if v_room.pending_item is not null then raise exception 'Resolva o item pendente primeiro'; end if;

  select * into v_player from public.players where id = v_room.current_player_id for update;
  if v_player.id is null or v_player.finish_position is not null or v_player.is_spectator then
    raise exception 'Piloto inválido';
  end if;
  if auth.uid() not in (v_player.owner_id, v_room.owner_id) then raise exception 'Não é a sua vez'; end if;

  v_roll_event := jsonb_build_object(
    'id', gen_random_uuid(), 'player_id', v_player.id,
    'value', v_roll, 'created_at', now()
  );
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
      v_new_score := v_new_score + 10;
      v_turbo_before_finish := true;
      update public.players set score = v_new_score where id = v_player.id;
      v_event := jsonb_build_object(
        'id', gen_random_uuid(), 'type', 'turbo', 'source_id', v_player.id,
        'target_id', null, 'boost', 10, 'lap', v_lap, 'marker', v_marker,
        'created_at', now()
      );
    elsif exists (
      select 1 from public.players opponent
      where opponent.room_id = v_room.id and opponent.id <> v_player.id
        and opponent.finish_position is null and opponent.is_spectator = false
    ) then
      v_pending := jsonb_build_object(
        'player_id', v_player.id, 'type', v_item, 'damage', v_damage,
        'lap', v_lap, 'marker', v_marker,
        'expires_at', now() + interval '1 minute'
      );
    else
      v_event := jsonb_build_object(
        'id', gen_random_uuid(), 'type', 'no_target', 'item_type', v_item,
        'source_id', v_player.id, 'damage', v_damage,
        'lap', v_lap, 'marker', v_marker, 'created_at', now()
      );
    end if;
  end loop;

  if v_new_score >= v_total then
    select count(*) + 1 into v_position from public.players
    where room_id = v_room.id and finish_position is not null;

    update public.players set score = v_total, finish_position = v_position,
      finished_at = now() where id = v_player.id;

    v_event := jsonb_build_object(
      'id', gen_random_uuid(), 'type', 'finish', 'source_id', v_player.id,
      'position', v_position, 'turbo_before_finish', v_turbo_before_finish,
      'boost', case when v_turbo_before_finish then 10 else 0 end,
      'created_at', now()
    );
    select public.next_player_id(v_room.id, v_player.id) into v_next;

    if v_next is null then
      update public.rooms set status = 'finished', current_player_id = null,
        pending_item = null, winner_id = (
          select id from public.players where room_id = v_room.id and finish_position = 1
        ), last_event = v_event, last_roll = v_roll_event where id = v_room.id;
    else
      update public.rooms set current_player_id = v_next, pending_item = null,
        winner_id = case when v_position = 1 then v_player.id else winner_id end,
        last_event = v_event, last_roll = v_roll_event where id = v_room.id;
    end if;
  elsif v_pending is not null then
    update public.rooms set pending_item = v_pending,
      last_event = coalesce(v_event, last_event), last_roll = v_roll_event
    where id = v_room.id;
  else
    update public.rooms set current_player_id = public.next_player_id(v_room.id, v_player.id),
      last_event = coalesce(v_event, last_event), last_roll = v_roll_event
    where id = v_room.id;
  end if;

  return jsonb_build_object(
    'roll', v_roll, 'item', v_item, 'pending_item', v_pending,
    'event', v_event, 'player_id', v_player.id,
    'score', least(v_new_score, v_total), 'finish_position', v_position
  );
end;
$$;

revoke all on function public.roll_d20_core_positions(text) from public, anon, authenticated;
