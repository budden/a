--/*
\connect sduser_db
\set ON_ERROR_STOP on
--*/ 

create or replace function get_language_slug(p_languageid int) returns text
 language plpgsql strict as $$
 declare v_result text;
 declare v_len_limit int;
  begin
  
  v_len_limit = 256;
  with recursive r as 
  (select id, parentid, cast(slug as text) from tlanguage
  where id = p_languageid 
  union 
  select r.id, tl.parentid, r.slug || '/' || tl.slug from r 
  left join tlanguage tl on tl.id = r.parentid 
  where tl.id is not null 
    or r.slug is null -- this should never happen as slug is not null, but just in case
    or length(r.slug) > v_len_limit -- guard against an unlimited recursion 
  )

  select slug from r 
  where parentid is null 
  into v_result;

  if length(v_result) > v_len_limit then
    v_result = 'bad slug for languageid='||p_languageid;
  end if;

  return v_result;
  end;
$$;

-- see also vsense_wide
create or replace view vsense as select s.*,
  ,case when s.ownerid is not null then s.originid else s.id end as commonid,
  ,case when s.ownerid is not null then s.id else null end as personalid
  from tsense s;




-- fnPersonalSenses returns all personal senses for the user. If the user is 0 or null,
-- then common senses are returned as well as unparallel personal
-- to copy-paste or complicate this one to have a good select plan for searches.
create or replace function fnpersonalsenses(p_sduserid bigint) 
  returns table(r_originid bigint, r_proposalid bigint, r_countofproposals bigint, r_addedbyme bool)
  language plpgsql as $$
  begin
  if coalesce(p_sduserid, 0) = 0 then
    return query(
      select cast(orig.id as bigint) as r_originid
      ,cast(null as bigint) as r_proposalid
      ,(select count(1) from tsense varic where varic.originid = orig.id) as r_countofproposals
      ,false as r_addedbyme
      from tsense orig where orig.originid is null and orig.ownerid is null); 
  else
    return query(
      select cast(orig.id as bigint) as r_originid
      ,cast(vari.id as bigint) as r_proposalid
      ,(select count(1) from tsense varic where varic.originid = orig.id) as r_countofproposals
      ,case when orig.ownerid = p_sduserid then true else false end as r_addedbyme
      from tsense orig 
      left join tsense vari on orig.id = vari.originid and vari.ownerid = p_sduserid 
      where orig.originid is null); end if; end;
$$;


-- fnOnePersonalSense returns a personal or common sense for the specific sense id
create or replace function fnonepersonalsense(p_sduserid bigint, p_originid bigint) 
  returns table(r_originid bigint, r_proposalid bigint)
  language plpgsql as $$
  begin
  return query(
    select cast(orig.id as bigint) as r_originid, cast(vari.id as bigint) as r_proposalid 
    from tsense orig 
    left join tsense vari on orig.id = vari.originid and vari.ownerid = p_sduserid 
    where orig.id = p_originid and orig.originid is null); end;
$$;

-- fnSavePersonalSense saves the sense. p_evenifidentical must be false for now
-- Use cases:
/* originid is not null, proposalid is null:
    We are adding proposal to the existing sense
   originid is not null, proposalid is not null
    We are updating a pre-existing proposal */
create or replace function fnsavepersonalsense(
    p_sduserid bigint, p_proposalid bigint, p_originid bigint, p_phrase text, p_word text, p_evenifidentical bool)
  returns table (success bool)
  language plpgsql as $$
  declare v_deleted bool;
  declare update_count int;
  declare v_originid bigint;
  declare v_proposalid bigint;
  begin
  if p_originid is null then
    raise exception 'p_originid must not be null'; end if;
  if p_evenifidentical then
    raise exception 'invalid parameter p_evenifidentical'; end if;
  if p_proposalid is not null then
    select originid, deleted 
    from tsense where id = p_proposalid into v_originid, v_deleted;
    if coalesce(v_originid, 0) <> p_originid then
      raise exception 'origin mismatch'; end if;
    if exists (select 1 from tsense where 
      id = v_originid 
      and word = p_word 
      and phrase = p_phrase 
      and deleted = v_deleted) then
    -- nothing differs from the official version, delete our proposal
      delete from tsense where id = p_proposalid;
      return query(select true); return; end if;
    v_proposalid = p_proposalid;
  else -- hence p_proposalid is null
    select ensuresenseproposal(p_sduserid, v_originid) into v_proposalid; end if;
  
  update tsense set 
    phrase = p_phrase,
    word = p_word
    where id = v_proposalid;

  get diagnostics update_count = row_count;
  if update_count != 1 then
    raise exception 'expected to update just one record, which didn''t hapen'; end if;
  return query(select true); return; end;
$$;

-- EnsureSenseProposal ensures that a user has his own proposal of a sense. One should not
-- make a proposal of user's unparallel sense.
create or replace function ensuresenseproposal(p_sduserid bigint, p_senseid bigint)
returns table (proposalsenseid bigint) 
language plpgsql as $$
  declare r_senseid bigint;
  declare v_ownerid bigint;
  begin
    lock table themutex;
    select ownerid from tsense where id = p_senseid into v_ownerid;
    if v_ownerid is not null then
      raise exception 
      'You can''t make a proposal of user''s new sense, until it is accepted to the language'; end if;
    select min(id) from tsense 
      where originid = p_senseid and ownerid = p_sduserid
      into r_senseid;
    if r_senseid is not null then 
      return query (select r_senseid); 
      return; end if;
    insert into tsense (languageid, phrase, word, originid, ownerid)
      select languageid, phrase, word, id, p_sduserid 
      from tsense where id = p_senseid returning id into r_senseid;
    if r_senseid is null then
      raise exception 
        'something went wrong, sense cloning failed'; 
    end if;
  return query (select r_senseid);
  end;
$$;

-- this is a mess...
select ensuresenseproposal(1,4);
update tsense set phrase = 'updated sense' where id=5;

-- end of mess

create or replace function explainSenseStatusVsProposals(
    p_commonid bigint, p_personalid bigint, p_sduserid bigint, p_ownerid bigint, p_deleted bool) 
  returns
  table (commonorproposal varchar(128), whos varchar(512), kindofchange varchar(128))
  language plpgsql CALLED ON NULL INPUT as $$
  declare r_commonorproposal varchar(128);
  declare r_whos varchar(512);
  declare r_kindofchange varchar(128);
begin
  r_commonorproposal = case
    when coalesce(p_personalid,0) = 0 then 'common' 
    else 'proposal' end;
  r_whos = case 
    when coalesce(p_ownerid,0) = 0 then '' -- common - irrelevant
    when p_sduserid = p_ownerid then '<my>' 
    else 
      coalesce((select nickname from sduser where id = p_ownerid)
        ,'owner not found') end;
  r_kindofchange = case
    when p_ownerid is null then '' -- common - irrelevant
    when p_commonid is null then 'addition'
    when p_deleted then 'deletion'
    else 'change' end;
  return query(select r_commonorproposal, r_whos, r_kindofchange); end;
$$;


create or replace function fnsenseorproposalforview(p_sduserid bigint, p_id bigint, p_byoriginid bool)
returns table (senseorproposalid bigint
  ,originid bigint
  ,phrase text
  ,word varchar(512)
  ,deleted bool
  ,languageslug text
  ,commonorproposal varchar(128)
  ,whos varchar(512)
  ,kindofchange varchar(128)
  )
language plpgsql as $$
  begin
  if p_byoriginid then
    return query(
      select cast(s.id as bigint) as senseorproposalid
        ,cast(coalesce(s.originid,0) as bigint) as originid
        ,s.phrase, s.word
  	    ,s.deleted 
        ,s.languageslug
        ,(explainSenseStatusVsProposals(s.id, s.originid, p_sduserid, s.ownerid, s.deleted)).*
	      from fnonepersonalsense(p_sduserid, p_id) ops
  		  left join vsense as s on s.id = coalesce(ops.r_proposalid, ops.r_originid)
        limit 1);
  else
    return query(
      select cast(s.id as bigint) senseorproposalid
        ,cast(coalesce(s.originid,0) as bigint) as originid
        ,s.phrase, s.word
    	  ,s.deleted 
        ,s.languageslug
        ,(explainSenseStatusVsProposals(s.id, s.originid, p_sduserid, s.ownerid, s.deleted)).*
  	    from vsense as s where s.id = p_id
			  limit 1); end if; end;
$$;

-- tests
create or replace function test_fnsensorproposalforview() returns void
language plpgsql strict as $$
begin
 if not exists (select originid, senseorproposalid from fnsenseorproposalforview(1,1,true) 
  where originid = 0 and senseorproposalid = 1) THEN
   raise exception 'test_fnsensorproposalforview failure 1'; end if; 
 if not exists (select originid, senseorproposalid from fnsenseorproposalforview(1,1,false) 
  where originid = 0 and senseorproposalid = 1) THEN
   raise exception 'test_fnsensorproposalforview failure 2'; end if; 
end;
$$;

select test_fnsensorproposalforview();

-- see also vsense
create or replace view vsense_wide as select s.*,
  ,case when s.ownerid is not null then s.originid else s.id end as commonid,
  ,case when s.ownerid is not null then s.id else null end as personalid,
  ,u.nickname as sduser_nickname
  -- FIXME suboptimal!
  ,get_language_slug(s.languageid) as languageslug
  from tsense s left join sduser u on s.ownerid=u.id;



\echo *** language_and_sense.sql Done
