-- Executa a limpeza de salas automaticamente, mesmo sem clientes conectados.

create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.cleanup_abandoned_rooms()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_deleted integer;
begin
  delete from public.room_presence
  where last_seen_at < now() - interval '5 minutes';

  delete from public.rooms room
  where not exists (
    select 1 from public.room_presence presence
    where presence.room_id = room.id
  )
  and room.updated_at < now() - interval '5 minutes';

  get diagnostics v_deleted = row_count;
  perform public.cleanup_old_anonymous_users();
  return v_deleted;
end;
$$;

revoke all on function public.cleanup_abandoned_rooms() from public, anon;
grant execute on function public.cleanup_abandoned_rooms() to authenticated;

do $$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid from cron.job where jobname = 'cleanup-abandoned-racing-rooms'
  loop
    perform cron.unschedule(v_job_id);
  end loop;
end;
$$;

select cron.schedule(
  'cleanup-abandoned-racing-rooms',
  '* * * * *',
  'select public.cleanup_abandoned_rooms()'
);
