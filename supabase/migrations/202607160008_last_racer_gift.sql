-- Revela presentes ofensivos do último corredor sem exigir seleção de alvo.

alter function public.roll_d20_core(text) rename to roll_d20_core_positions;
revoke all on function public.roll_d20_core_positions(text) from public, anon, authenticated;

create or replace function public.roll_d20_core(p_room_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_result jsonb;
  v_room public.rooms;
  v_player public.players;
  v_event jsonb;
begin
  v_result := public.roll_d20_core_positions(p_room_code);

  if v_result->>'item' in ('shell', 'banana', 'lightning')
    and v_result->'pending_item' = 'null'::jsonb then
    select * into v_room from public.rooms where code = upper(p_room_code) for update;
    select * into v_player from public.players
      where id = (v_result->>'player_id')::uuid;

    if v_room.status = 'racing' and v_player.finish_position is null then
      v_event := jsonb_build_object(
        'id', gen_random_uuid(), 'type', 'no_target',
        'item_type', v_result->>'item', 'source_id', v_player.id,
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
