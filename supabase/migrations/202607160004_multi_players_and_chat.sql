-- Limite configurável de corredores por usuário e chat temporário por corredor.

alter table public.rooms
  add column if not exists max_players_per_user smallint not null default 1
  check (max_players_per_user between 1 and 5);

alter table public.players drop constraint if exists players_room_id_owner_id_key;

drop policy if exists "users can create their own player" on public.players;
create policy "users can create their own player"
on public.players for insert to authenticated
with check (
  (select auth.uid()) = owner_id
  and exists (
    select 1 from public.rooms r
    where r.id = room_id and r.status = 'lobby'
      and (select count(*) from public.players p
        where p.room_id = r.id and p.owner_id = (select auth.uid())) < r.max_players_per_user
  )
);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  message text not null check (char_length(message) between 1 and 120),
  emote text not null default 'none' check (emote in ('none','wave','laugh','fire','wow','gg')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '20 seconds')
);

create index if not exists chat_messages_room_id_idx on public.chat_messages(room_id);
alter table public.chat_messages enable row level security;

drop policy if exists "room participants can view chat" on public.chat_messages;
create policy "room participants can view chat"
on public.chat_messages for select to authenticated using (
  exists (select 1 from public.players p where p.room_id = chat_messages.room_id and p.owner_id = (select auth.uid()))
  or exists (select 1 from public.rooms r where r.id = chat_messages.room_id and r.owner_id = (select auth.uid()))
);

create or replace function public.send_chat_message(
  p_room_code text, p_player_id uuid, p_message text, p_emote text default 'none'
)
returns public.chat_messages
language plpgsql security definer set search_path = '' as $$
declare
  v_room public.rooms;
  v_player public.players;
  v_message text := btrim(p_message);
  v_result public.chat_messages;
begin
  select * into v_room from public.rooms where code = upper(p_room_code);
  if v_room.id is null then raise exception 'Sala não encontrada'; end if;
  select * into v_player from public.players where id = p_player_id and room_id = v_room.id;
  if v_player.id is null or v_player.owner_id <> auth.uid() then
    raise exception 'Você só pode falar por um corredor seu';
  end if;
  if char_length(v_message) not between 1 and 120 then
    raise exception 'A mensagem deve ter entre 1 e 120 caracteres';
  end if;
  if coalesce(p_emote, 'none') not in ('none','wave','laugh','fire','wow','gg') then
    raise exception 'Emote inválido';
  end if;
  delete from public.chat_messages where room_id = v_room.id and expires_at <= now();
  insert into public.chat_messages(room_id, player_id, owner_id, message, emote)
    values(v_room.id, v_player.id, auth.uid(), v_message, coalesce(p_emote, 'none'))
    returning * into v_result;
  return v_result;
end;
$$;

revoke all on function public.send_chat_message(text, uuid, text, text) from public, anon;
grant execute on function public.send_chat_message(text, uuid, text, text) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_messages'
  ) then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
end $$;
