\set ON_ERROR_STOP on
DROP DATABASE IF EXISTS sduser_db;
CREATE DATABASE sduser_db;
\connect sduser_db
/* END_CREATE - keep this line intact. It is used to make the test db */

\set ON_ERROR_STOP on
\set thisdir `echo "$GOPATH/src/github.com/budden/semdict/"`
-- \set thisdir `pwd`

\i :thisdir/sql/forward_declarations.sql
\i :thisdir/sql/mutex.sql
\i :thisdir/sql/email.sql
\i :thisdir/sql/user_registration_session.sql
\i :thisdir/sql/language_and_sense_tbl.sql
\i :thisdir/sql/language_and_sense_view_1.sql
\i :thisdir/sql/language_and_sense_fn.sql
\i :thisdir/sql/language_and_sense_test.sql
\i :thisdir/sql/privilege.sql

\echo *** recreate_sduser_db.sql Done
