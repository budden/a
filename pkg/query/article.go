package query

import (
	"fmt"
	"html/template"
	"net/http"

	"github.com/budden/semdict/pkg/apperror"
	"github.com/budden/semdict/pkg/sddb"

	"github.com/budden/semdict/pkg/shared"
	"github.com/budden/semdict/pkg/user"
	"github.com/gin-gonic/gin"
)

// params for a query for a word
type senseViewDirHandlerParams struct {
	Id       int64
	Sduserid int32
	/// if true, we show current user's proposal, if there is one. If there is no one, we show common sense
	/// if false, we show just exact Id given, regardless of whether it is a common sense or proposal
	Proposalifexists bool
}

// FIXME shall we create a record for each query?
type senseDataForEditType struct {
	Senseid      int64 // it is an origin id, not proposal id
	Languageslug string
	Phrase       string
	Word         string
	Deleted      bool
}

type senseEditTemplateParams struct {
	Ad *senseDataForEditType
}

// SenseViewDirHandler ...
func SenseViewDirHandler(c *gin.Context) {
	avdhp := &senseViewDirHandlerParams{
		Id:               extractIdFromRequest(c),
		Sduserid:         user.GetSDUserIdOrZero(c),
		Proposalifexists: false}
	dataFound, ad := readSenseFromDb(avdhp)

	if dataFound {
		c.HTML(http.StatusOK,
			"senseview.t.html",
			shared.SenseViewParams{Id: ad.Senseid, Word: ad.Word, Phrase: template.HTML(ad.Phrase)})
	} else {
		apperror.Panic500AndErrorIf(apperror.ErrDummy, "Sorry, no sense (yet?) with id = «%d»", avdhp.Id)
	}
}

// read the sense appropriate for edit. That is, either mine or a common one.
func readSenseFromDb(avdhp *senseViewDirHandlerParams) (dataFound bool, ad *senseDataForEditType) {
	reply, err1 := sddb.NamedReadQuery(
		`select 
			ops.r_originid as senseid
			,s.phrase
			,s.word
			,s.deleted 
			,s.languageslug
			from fnonepersonalsense(:sduserid, :id) ops
			left join vsense as s on s.id = coalesce(ops.r_proposalid, ops.r_originid)
			limit 1`, &avdhp)
	apperror.Panic500AndErrorIf(err1, "Failed to extract an article, sorry")
	ad = &senseDataForEditType{}
	for reply.Next() {
		err1 = reply.StructScan(ad)
		dataFound = true
	}
	sddb.FatalDatabaseErrorIf(err1, "Error obtaining data of sense: %#v", err1)
	return
}

// SenseEditDirHandler is a handler to open a user's proposal, or an original record if there
// is no user's proposal
func SenseEditDirHandler(c *gin.Context) {
	user.EnsureLoggedIn(c)
	avdhp := &senseViewDirHandlerParams{
		Id:       extractIdFromRequest(c),
		Sduserid: user.GetSDUserIdOrZero(c)}

	dataFound, ad := readSenseFromDb(avdhp)

	if !dataFound {
		c.HTML(http.StatusBadRequest,
			"general.t.html",
			shared.GeneralTemplateParams{Message: fmt.Sprintf("Sorry, no sense (yet?) for «%d»", avdhp.Id)})
		return
	}

	aetp := &senseEditTemplateParams{Ad: ad}
	c.HTML(http.StatusOK,
		"senseedit.t.html",
		aetp)
}
