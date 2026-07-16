-- Exibe o Turbo para todos e permite que o impulso alcance outro presente.

create or replace function public.roll_d20(p_room_code text)
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
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null then raise exception 'Sala não encontrada'; end if;
  if v_room.status <> 'racing' then raise exception 'A corrida não está ativa'; end if;
  if v_room.pending_item is not null then raise exception 'Resolva o item pendente primeiro'; end if;

  select * into v_player from public.players where id = v_room.current_player_id for update;
  if v_player.id is null then raise exception 'Não há piloto para jogar'; end if;
  if auth.uid() not in (v_player.owner_id, v_room.owner_id) then raise exception 'Não é a sua vez'; end if;

  v_old_score := v_player.score;
  v_new_score := v_old_score + v_roll;
  v_total := v_room.laps * 100;
  update public.players set score = v_new_score, roll_count = roll_count + 1 where id = v_player.id;

  -- Busca sempre o próximo marco atravessado. Se vier Turbo, amplia o percurso
  -- e repete a busca, possibilitando coletar o marco seguinte na mesma jogada.
  while v_new_score < v_total and v_pending is null loop
    select route.lap, route.marker, route.absolute
      into v_lap, v_marker, v_absolute
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
    order by route.absolute
    limit 1;

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
      v_event := jsonb_build_object(
        'id', gen_random_uuid(), 'type', 'turbo', 'source_id', v_player.id,
        'target_id', null, 'boost', 15, 'lap', v_lap, 'marker', v_marker,
        'created_at', now()
      );
    else
      v_pending := jsonb_build_object(
        'player_id', v_player.id, 'type', v_item, 'damage', v_damage,
        'lap', v_lap, 'marker', v_marker,
        'expires_at', now() + interval '1 minute'
      );
    end if;
  end loop;

  if v_new_score >= v_total then
    update public.rooms set status = 'finished', winner_id = v_player.id,
      pending_item = null, last_event = coalesce(v_event, last_event)
      where id = v_room.id;
  elsif v_pending is not null then
    update public.rooms set pending_item = v_pending,
      last_event = coalesce(v_event, last_event) where id = v_room.id;
  else
    update public.rooms set current_player_id = public.next_player_id(v_room.id, v_player.id),
      last_event = coalesce(v_event, last_event) where id = v_room.id;
  end if;

  return jsonb_build_object(
    'roll', v_roll, 'item', v_item, 'pending_item', v_pending,
    'event', v_event, 'player_id', v_player.id, 'score', v_new_score,
    'winner_id', case when v_new_score >= v_total then v_player.id else null end
  );
end;
$$;

revoke all on function public.roll_d20(text) from public, anon;
grant execute on function public.roll_d20(text) to authenticated;
