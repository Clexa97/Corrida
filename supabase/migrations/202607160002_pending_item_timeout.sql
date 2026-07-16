-- Aplica prazo de 60 segundos aos presentes e permite expiração transacional.

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
  v_item text;
  v_damage integer;
  v_pending jsonb := null;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.status <> 'racing' then raise exception 'A corrida não está ativa'; end if;
  if v_room.pending_item is not null then raise exception 'Resolva o item pendente primeiro'; end if;
  select * into v_player from public.players where id = v_room.current_player_id for update;
  if auth.uid() not in (v_player.owner_id, v_room.owner_id) then raise exception 'Não é a sua vez'; end if;

  v_old_score := v_player.score;
  v_new_score := v_old_score + v_roll;
  v_total := v_room.laps * 100;
  update public.players set score = v_new_score, roll_count = roll_count + 1 where id = v_player.id;

  if v_new_score >= v_total then
    update public.rooms set status = 'finished', winner_id = v_player.id where id = v_room.id;
    return jsonb_build_object('roll', v_roll, 'winner_id', v_player.id);
  end if;

  for v_lap in 1..v_room.laps loop
    foreach v_marker in array array[25, 50, 75] loop
      v_absolute := (v_lap - 1) * 100 + v_marker;
      if v_old_score < v_absolute and v_new_score >= v_absolute and not exists (
        select 1 from public.claimed_gifts
        where player_id = v_player.id and lap = v_lap and marker = v_marker
      ) then
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
        else
          v_pending := jsonb_build_object('player_id', v_player.id, 'type', v_item,
            'damage', v_damage, 'lap', v_lap, 'marker', v_marker,
            'expires_at', now() + interval '1 minute');
        end if;
        exit;
      end if;
    end loop;
    exit when v_pending is not null or v_item = 'turbo';
  end loop;

  if v_new_score >= v_total then
    update public.rooms set status = 'finished', winner_id = v_player.id where id = v_room.id;
  elsif v_pending is not null then
    update public.rooms set pending_item = v_pending where id = v_room.id;
  else
    update public.rooms set current_player_id = public.next_player_id(v_room.id, v_player.id) where id = v_room.id;
  end if;

  return jsonb_build_object('roll', v_roll, 'item', v_item, 'pending_item', v_pending,
    'player_id', v_player.id, 'score', v_new_score);
end;
$$;

create or replace function public.use_pending_item(p_room_code text, p_target_player_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_source public.players;
  v_target public.players;
  v_damage integer;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.pending_item is null then raise exception 'Não há item pendente'; end if;
  select * into v_source from public.players where id = (v_room.pending_item->>'player_id')::uuid;
  if now() >= (v_room.pending_item->>'expires_at')::timestamptz then
    update public.rooms set pending_item = null,
      current_player_id = public.next_player_id(v_room.id, v_source.id) where id = v_room.id;
    return jsonb_build_object('expired', true);
  end if;
  if auth.uid() not in (v_source.owner_id, v_room.owner_id) then raise exception 'Sem permissão para usar este item'; end if;
  select * into v_target from public.players where id = p_target_player_id and room_id = v_room.id for update;
  if v_target.id is null or v_target.id = v_source.id then raise exception 'Alvo inválido'; end if;
  v_damage := (v_room.pending_item->>'damage')::integer;
  update public.players set score = greatest(0, score - v_damage) where id = v_target.id;
  update public.rooms set pending_item = null,
    current_player_id = public.next_player_id(v_room.id, v_source.id),
    last_event = jsonb_build_object('id', gen_random_uuid(), 'type', v_room.pending_item->>'type',
      'source_id', v_source.id, 'target_id', v_target.id, 'damage', v_damage, 'created_at', now())
    where id = v_room.id;
  return jsonb_build_object('target_id', v_target.id, 'damage', v_damage);
end;
$$;

create or replace function public.expire_pending_item(p_room_code text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_source_id uuid;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null or v_room.pending_item is null then return false; end if;
  if now() < (v_room.pending_item->>'expires_at')::timestamptz then return false; end if;
  v_source_id := (v_room.pending_item->>'player_id')::uuid;
  update public.rooms set pending_item = null,
    current_player_id = public.next_player_id(v_room.id, v_source_id) where id = v_room.id;
  return true;
end;
$$;

revoke all on function public.expire_pending_item(text) from public, anon;
grant execute on function public.expire_pending_item(text) to authenticated;
