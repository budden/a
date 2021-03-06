package app

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

type formDataType map[string]io.Reader

const (
	serverHost     = "localhost"
	serverPort     = "5432"
	serverDatabase = "sduser_test_db"
	serviceURL     = "http://localhost:8085"
)

var (
	auxCloser chan int
	// if database creation failed, we terminate the test
	databaseCreationFailed bool
)

func setupClient() (err error) {

	/*	var client = &http.Client{Timeout: time.Second * 10}
		apiURL := serviceURL + "/api/connect"

		formData := formDataType{"url": strings.NewReader(shared.SecretConfigData.PostgresqlServerURL)}
		var req *http.Request
		req, err = preparePostRequest(apiURL, formData)
		if err != nil {
			return
		}

		// Submit the request
		var res *http.Response
		res, err = client.Do(req)
		if err != nil {
			return
		}

		// Check the response
		if res.StatusCode != http.StatusOK {
			err = decodeErrorFromHTTPResponsesBody(res)
		}*/
	return
}

func decodeErrorFromHTTPResponsesBody(res *http.Response) (err error) {
	var body map[string]interface{}
	err = json.NewDecoder(res.Body).Decode(&body)
	if err == nil {
		err = fmt.Errorf("Http response status %v, response body is %#v", res.StatusCode, body)
	}
	return
}

/* func teardownClient() (err error) {
	// disconnect here
	var client = &http.Client{Timeout: time.Second * 1000}
	var req *http.Request
	req, err = preparePostRequest(serviceURL+"/api/disconnect", formDataType{})
	if err != nil {
		return
	}

	// Submit the request
	var res *http.Response
	res, err = client.Do(req)
	if err != nil {
		return
	}

	// Check the response
	if res.StatusCode != http.StatusOK {
		err = decodeErrorFromHTTPResponsesBody(res)
	}
	return
}*/

// Produces error if the query fails or result does not match the expectation
func errIfQueryResultMismatch(t *testing.T, query, expectedResult string) (err error) {
	var client *http.Client
	client = &http.Client{Timeout: time.Second * 10}
	apiURL := "http://localhost:????/api/query"

	fd := formDataType{
		"query": strings.NewReader(query),
	}

	var req *http.Request
	req, err = preparePostRequest(apiURL, fd)
	// Now that you have a form, you can submit it to your handler.
	if err != nil {
		return
	}

	// Submit the request
	var res *http.Response
	res, err = client.Do(req)
	if err != nil {
		return
	}

	// Check the response
	if res.StatusCode != http.StatusOK {
		err = decodeErrorFromHTTPResponsesBody(res)
		return
	}

	defer res.Body.Close()
	var htmlData []byte
	htmlData, err = ioutil.ReadAll(res.Body)
	if err != nil {
		return
	}

	actualResult := string(htmlData)
	if expectedResult != actualResult {
		err = fmt.Errorf("Query «%s», expected «%s», actual «%s»", query, expectedResult, actualResult)
		return
	}

	return
}

func preparePostRequest(apiURL string, formData map[string]io.Reader) (req *http.Request, err error) {
	req = nil
	var b bytes.Buffer
	w := multipart.NewWriter(&b)
	for key, r := range formData {
		var fw io.Writer
		if x, ok := r.(io.Closer); ok {
			defer x.Close()
		}
		if x, ok := r.(*os.File); ok {
			if fw, err = w.CreateFormFile(key, x.Name()); err != nil {
				return
			}
		} else {
			// Add other fields
			if fw, err = w.CreateFormField(key); err != nil {
				return
			}
		}
		if _, err = io.Copy(fw, r); err != nil {
			return
		}

	}
	// Don't forget to close the multipart writer.
	// If you don't close it, your request will be missing the terminating boundary.
	w.Close()
	req, err = http.NewRequest("POST", apiURL, &b)

	// Don't forget to set the content type, this will contain the boundary.
	req.Header.Set("Content-Type", w.FormDataContentType())
	sessionID := "test-sess-ion-id"
	req.Header.Add("x-session-id", sessionID)

	return
}

func mustOpen(f string) *os.File {
	r, err := os.Open(f)
	if err != nil {
		panic(err)
	}
	return r
}

// returns true if there is an error
func reportIfErr(err error) bool {
	if err != nil {
		fmt.Println(err)
		return false
	}
	return true
}

func setupDatabase(t *testing.T) {
	t.Run("createdb", createdb)
	if t.Failed() {
		return
	}
	t.Run("writeTestDbSetupScript", writeTestDbSetupScript)
	if t.Failed() {
		return
	}
	t.Run("executeTestDbSetupScript", executeTestDbSetupScript)
	if t.Failed() {
		return
	}
	t.Run("deleteTestDbSetupScript", deleteTestDbSetupScript)
}

func createdb(t *testing.T) {
	out, err := exec.Command(
		"createdb",
		"-h", serverHost,
		"-p", serverPort,
		serverDatabase,
	).CombinedOutput()

	if err != nil {
		log.Printf("Create db failed. Error message: «%s», OS command output: «%s»", err.Error(), string(out))
		databaseCreationFailed = true
		t.Fail()
	}
}

const markAtTheEndOfDbCreationCode = "/* END_CREATE - keep this line intact. It is used to make the test db */"
const testDbSetupScriptFileName = "setup_sduser_test_db.sql"

func writeTestDbSetupScript(t *testing.T) {
	bytes, err := ioutil.ReadFile("../../sql/recreate_sduser_db.sql")
	if err != nil {
		log.Printf("Failed to read sql script, error is %#v", err)
		t.Fail()
		return
	}
	str := string(bytes)
	i := strings.Index(str, markAtTheEndOfDbCreationCode)
	if i < 0 {
		log.Printf("Didn't find a mark in the sql/recreate_sduser_db.sql")
		t.Fail()
		return
	}
	str = str[i:]
	str = strings.TrimPrefix(str, markAtTheEndOfDbCreationCode)
	bytes = []byte(str)
	err = ioutil.WriteFile(testDbSetupScriptFileName, bytes, 0600)
	if err != nil {
		log.Printf("«%#v»", err)
		t.Fail()
	}
}

func executeTestDbSetupScript(t *testing.T) {
	out, err := exec.Command(
		"psql",
		"-h", serverHost,
		"-p", serverPort,
		serverDatabase,
		"--file="+testDbSetupScriptFileName).CombinedOutput()

	if err != nil {
		log.Printf("Test db setup script failed. Error message: «%s», db command output: «%s»", err.Error(), string(out))
		t.Fail()
	}
}

func deleteTestDbSetupScript(t *testing.T) {
	if os.Remove(testDbSetupScriptFileName) != nil {
		t.Fail()
	}
}

func teardownDatabase(t *testing.T) {
	out, err := exec.Command(
		"dropdb",
		"--if-exists",
		"-h", serverHost,
		"-p", serverPort,
		serverDatabase).CombinedOutput()

	if err != nil {
		log.Printf("Dropdb failed. Error message: «%s», drop db command output: «%s»", err.Error(), string(out))
		t.Fail()
	}
}
