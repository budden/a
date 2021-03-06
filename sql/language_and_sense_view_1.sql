--/*
\connect sduser_db
\set ON_ERROR_STOP on
--*/ 

/* Views are of limited use for the sense, because
  all interesting queries have a p_sduserid parameter. So think
  twice before adding a new view! */

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
/* there are four interpreation of sense id:
 - senseid == tsense.id, regardless of if sense is a common sense or a proposal
 - tsense.originid is a common sense for change and delete proposals
 - commonid is an id of common sense, if this sense is common or a change or delete proposal
 - proposalid is an id, if this sense is a proposal
 */
create or replace view vsense as select s.*
  ,coalesce(case when s.ownerid is not null then s.originid else cast(s.id as bigint) end,0) as commonid
  ,coalesce(case when s.ownerid is not null then cast(s.id as bigint) else null end,0) as proposalid
  ,cast(s.id as bigint) as senseid
  from tsense s;

-- see also vsense
create or replace view vsense_wide as select s.*
  ,coalesce(case when s.ownerid is not null then s.originid else cast(s.id as bigint) end,0) as commonid
  ,coalesce(case when s.ownerid is not null then cast(s.id as bigint) else null end,0) as proposalid
  ,cast(s.id as bigint) as senseid
  ,u.nickname as sdusernickname
  -- FIXME suboptimal!
  ,get_language_slug(s.languageid) as languageslug
  from tsense s left join sduser u on s.ownerid=u.id;


\echo *** language_and_sense_view_1.sql Done
