-- Chat sem cintilação/emoji-only e controle do anfitrião após 60s de ausência.

alter table public.rooms
  add column if not exists turn_started_at timestamptz not null default now();

create or replace function public.set_turn_started_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.current_player_id is distinct from new.current_player_id
    or (new.status = 'racing' and old.status is distinct from new.status) then
    new.turn_started_at = now();
  end if;
  return new;
end;
$$;

drop trigger if exists rooms_set_turn_started_at on public.rooms;
create trigger rooms_set_turn_started_at
before update of current_player_id, status on public.rooms
for each row execute function public.set_turn_started_at();

-- Mantém a lógica completa da rolagem anterior como núcleo e coloca a
-- autorização temporal em uma função pública com o mesmo nome da RPC.
alter function public.roll_d20(text) rename to roll_d20_core;
revoke all on function public.roll_d20_core(text) from public, anon, authenticated;

create or replace function public.roll_d20(p_room_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_player public.players;
begin
  select * into v_room from public.rooms where code = upper(p_room_code) for update;
  if v_room.id is null then raise exception 'Sala não encontrada'; end if;
  select * into v_player from public.players where id = v_room.current_player_id;
  if v_player.id is null then raise exception 'Não há piloto para jogar'; end if;

  if auth.uid() = v_player.owner_id then
    return public.roll_d20_core(p_room_code);
  end if;

  if auth.uid() = v_room.owner_id then
    if now() < v_room.turn_started_at + interval '1 minute' then
      raise exception 'O anfitrião deve aguardar o tempo de ausência do piloto';
    end if;
    return public.roll_d20_core(p_room_code);
  end if;

  raise exception 'Não é a sua vez';
end;
$$;

revoke all on function public.roll_d20(text) from public, anon;
grant execute on function public.roll_d20(text) to authenticated;

drop policy if exists "player owner or room owner can delete player" on public.players;
create policy "player owner or room owner can delete player"
on public.players for delete to authenticated using (
  (select auth.uid()) = owner_id
  or exists (
    select 1 from public.rooms r
    where r.id = room_id and r.owner_id = (select auth.uid())
      and (
        r.status <> 'racing'
        or (r.current_player_id = players.id and now() >= r.turn_started_at + interval '1 minute')
      )
  )
);

alter table public.chat_messages drop constraint if exists chat_messages_message_check;
alter table public.chat_messages drop constraint if exists chat_messages_emote_check;
alter table public.chat_messages
  add constraint chat_messages_message_check check (char_length(message) between 0 and 120),
  add constraint chat_messages_emote_check check (emote in ('none','wave','laugh','fire','wow','gg','sad','angry')),
  add constraint chat_messages_content_check check (char_length(btrim(message)) > 0 or emote <> 'none');

create or replace function public.send_chat_message(
  p_room_code text, p_player_id uuid, p_message text, p_emote text default 'none'
)
returns public.chat_messages
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_player public.players;
  v_message text := btrim(coalesce(p_message, ''));
  v_emote text := coalesce(p_emote, 'none');
  v_result public.chat_messages;
begin
  select * into v_room from public.rooms where code = upper(p_room_code);
  if v_room.id is null then raise exception 'Sala não encontrada'; end if;
  select * into v_player from public.players where id = p_player_id and room_id = v_room.id;
  if v_player.id is null or v_player.owner_id <> auth.uid() then
    raise exception 'Você só pode falar por um corredor seu';
  end if;
  if char_length(v_message) > 120 then raise exception 'A mensagem deve ter até 120 caracteres'; end if;
  if v_emote not in ('none','wave','laugh','fire','wow','gg','sad','angry') then raise exception 'Emote inválido'; end if;
  if v_message = '' and v_emote = 'none' then raise exception 'Escreva uma mensagem ou escolha um emote'; end if;

  delete from public.chat_messages where room_id = v_room.id and expires_at <= now();
  insert into public.chat_messages(room_id, player_id, owner_id, message, emote)
    values(v_room.id, v_player.id, auth.uid(), v_message, v_emote)
    returning * into v_result;
  return v_result;
end;
$$;

revoke all on function public.send_chat_message(text, uuid, text, text) from public, anon;
grant execute on function public.send_chat_message(text, uuid, text, text) to authenticated;
