CREATE SEQUENCE sequence_sduser_id;

CREATE TYPE registrationattempt_status AS ENUM ('new', 'e-mail sent');

CREATE TABLE sduser (
 id bigint DEFAULT nextval('public.sequence_sduser_id') 
  NOT NULL primary key,
 nickname varchar(256) not null,
 registrationemail text not null,
 salt text not null,
 hash text NOT NULL,
 registrationtimestamp timestamptz not null
);

insert into sduser (nickname, registrationemail, salt, hash, registrationtimestamp)
values ('testuser','testuser@example.com','Fr5ISNGBVjsNUX1C5Q--Vw',
'qZwRJrl9O_VwBuQKJrMTYW1bh4zqNUAhMcmPyh5kBpo',current_timestamp);
-- password is aA$9bbbb

-- https://stackoverflow.com/a/9808332/9469533 - it is considered safe to lowercase an E-mail
create unique index 
 i_sduser_registrationemail 
 on sduser(lower(registrationemail));

create unique index
 i_sdusernickname
 on sduser(lower(nickname));

CREATE TABLE registrationattempt (
 id serial primary key,
 nickname varchar(256) not null,
 registrationemail text not null,
 salt text not null,
 hash text NOT NULL,
 confirmationkey text not null,
 registrationtimestamp timestamptz not null default current_timestamp,
 rastatus registrationattempt_status default 'new'
);

comment on table registrationattempt is 'registrationattempt gets a new record at each valid registration attempt. We keep registration attemps separated from users table for the case of registration flooding attack';
comment on column registrationattempt.confirmationkey is 'confirmationkey is random and as such it can be non-unique. In this case we ask user to re-register';

-- When a user is registrering with a both non-unique nickname and a non-unique E-mail, 
-- it is unspecified which unique constraint fires first (or I don't know).
-- It if fair to ask that nickname is checked first.
-- Experiment shows that the index first created is also first checked
-- But of course it is fragile (or, again, I don't know)
create unique index
 i_registrationattempt__nickname
 on registrationattempt(lower(nickname));

create unique index
 i_registrationattempt__registrationemail
 on registrationattempt(lower(registrationemail));


CREATE TABLE session (
  id serial primary key,
  -- won't hash sessions, 
  -- see https://security.stackexchange.com/questions/138389/should-i-also-hash-my-session-id-before-storing-it-in-the-database
  eid text not null,
  sduserid int not null, -- we omit fk intentionally
  expireat timestamptz not null -- expire at
);

create unique index i_session__eid on session (eid); 
create index i_session__sduserid on session (sduserid);

--- delete_expired_registrationattempts. 
--- We have a unique indices on a registrationemail and nickname. 
--- So we MUST delete all expired registrationattempts before adding new one 
--- with the same nickname. Cases to consider are:
--- i) old registrationattempt expired
--- ii) sending email for the old one failed
--- We could run it from the add_registrationattempt, but in this case
--- a request to add a non-unique nickname would cause deletion and then rollback.
--- So we run this one in a separated transaction. But we use single goroutine for all
--- activity related to sduser_db modifications, so calls to this one can't overlap
--- with other writes to the entire db.
create or replace function delete_expired_registrationattempts() 
returns void as $$
  declare 
    expiration_boundary timestamptz;
  begin
    lock table themutex;
    select current_timestamp - interval '10' minute into expiration_boundary;
    -- raise info 'expiration_boundary = %', expiration_boundary;
    delete from registrationattempt where registrationtimestamp <= expiration_boundary;
  end
$$ language plpgsql;

--- nickname and password must be unique in the union of registrationattempt and sduser tables
--- use repeatable read transaction and/or single threaded registration processor
create or replace function add_registrationattempt(p_nickname text
  ,p_salt text
  ,p_hash text
  ,p_registrationemail text
  ,p_confirmationkey text)
returns void as $$
 BEGIN
  lock table themutex;

  --- if a previous attempt failed at the stage of sending e-mail, rastatus will be 'new'
  delete from registrationattempt 
  where registrationemail = p_registrationemail and nickname = p_nickname and rastatus = 'new';

  if exists (select 1 from sduser ra where lower(ra.nickname)=lower(p_nickname)) THEN
    raise unique_violation using table = 'sduser', column = 'nickname', constraint = 'i_sdusernickname';
  end if;
  if exists (select 1 from sduser ra where lower(ra.registrationemail)=lower(p_registrationemail)) THEN
    raise unique_violation using table = 'sduser', column = 'registrationemail', constraint = 'i_sduser_registrationemail';
  end if;
  insert into registrationattempt(nickname, salt, hash, registrationemail, confirmationkey) 
    values (p_nickname, p_salt, p_hash, p_registrationemail, p_confirmationkey);
 end;
$$ language plpgsql;

create or replace function note_registrationconfirmation_email_sent(p_nickname text, p_confirmationkey text)
returns void as $$
  BEGIN
  lock table themutex;
  update registrationattempt set rastatus='e-mail sent' WHERE
  nickname = p_nickname and confirmationkey = p_confirmationkey;
  end;
$$ language plpgsql;

create or replace function process_registrationconfirmation(p_confirmationkey text, p_nickname text)
returns setof integer as $$
  declare v_id bigint := null;
  begin
    lock table themutex;
    insert into sduser (nickname, registrationemail, salt, hash, registrationtimestamp)
     select nickname, registrationemail, salt, hash, registrationtimestamp from registrationattempt 
     where confirmationkey = p_confirmationkey and nickname = p_nickname 
     and rastatus='e-mail sent' returning id into v_id;
    if v_id is null THEN
     -- there is no no_data condition_name, so we resort
     -- to sqlstate
     raise exception sqlstate '02000' using message = 'registrationattempt not found';
    end if;
    perform grantuserprivilege(v_id,1);
    -- we have a deadlock threat here in combination with the add_registrationattempt
    -- but we ensure at the application level that only one connection runs either of those procs
    -- simultaneously (all operations are protected with the mutex), so we don't care.
    -- But if we run those procs outside of our web app, deadlocks can occur in web app, so beware!
    delete from registrationattempt where confirmationkey = p_confirmationkey and nickname = p_nickname;
    return next v_id;
    end;
$$ language plpgsql;

-- begin_session. Return an id of a new session in a dataset. Tokens are random and may
-- clash. We will just fail with exception in this case in the service will crash. It is ok
-- due to low probability and crashing is our strategy in case anything wrong happens 
create or replace function begin_session(p_nickname text, p_token text)
returns table (sessionid integer) as $$
 declare v_sduserid int;
 declare v_count_of_sessions int;
 declare v_result int;
 BEGIN
  lock table themutex;
  delete from session where expireat <= current_timestamp;
  select id from sduser 
    where nickname = p_nickname 
    limit 1 into v_sduserid ;
  if v_sduserid is null then
    raise data_exception using table = 'begin_session', column = 'user_not_found', message = 'user not found';
  end if;
  -- in case someone would want to flood us with new sessions
  select count(1) 
    from 
    (select 1 from session 
      where sduserid = v_sduserid 
      limit 100) sessions_limited
    into v_count_of_sessions;
  if v_count_of_sessions = 100 then 
    -- TODO FIXME close old session if logging in while in session
    raise data_exception using table = 'begin_session', column = 'too_many_sessions', message = 'too many sessions for this user';
  end if;
  insert into session (eid, sduserid, expireat) values
  (p_token, v_sduserid, current_timestamp + interval '40' minute)
  returning id into v_result;
  return query(select v_result);
 END;
$$ language plpgsql;

create or replace function end_session(p_token text)
returns void as $$
  BEGIN
  lock table themutex;
  delete from session where expireat <= current_timestamp;
  delete from session where eid = p_token;
  END;
$$ language plpgsql;


\echo *** user_registration_session.sql Done