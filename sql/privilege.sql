\set ON_ERROR_STOP on

--/*
\connect sduser_db
drop table if exists tprivilegekind cascade;
drop table if exists tuserprivilege cascade;
drop table if exists tuserlanguageprivilege cascade;
--*/ 

-- FIXME perlanguage2 can help for translations
create table tprivilegekind (
  id int primary key,
  name varchar(128) not null,
  perlanguage bool not null
);

insert into tprivilegekind (id, name, perlanguage)
values
 (1,'Login',false)
 ,(2,'Manage access',false)
 ,(3,'Edit language attributes',false)
 ,(4,'Accept/decline change requests',true);

create table tuserprivilege (
  id serial primary key,
  sduserid int not null references sduser on delete cascade,
  privilegekindid int not null references tprivilegekind
);

create table tuserlanguageprivilege (
 id serial primary key,
 sduserid int not null references sduser on delete cascade,
 privilegekindid int not null references tprivilegekind,
 languageid int not null references tlanguage on delete cascade
);

insert into tuserprivilege (sduserid, privilegekindid)
 values
 (1,1)
 ,(1,2); 

insert into tuserlanguageprivilege (sduserid, privilegekindid, languageid)
 values
 (1,3,1)
 ,(1,3,2)
 ,(1,4,1)
 ,(1,4,2);

\echo *** privilege.sql Done
