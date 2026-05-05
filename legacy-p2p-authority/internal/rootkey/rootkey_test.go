package rootkey

import "testing"

func TestSignAndVerify(t *testing.T) {
	key, err := Load("test-root", "0000000000000000000000000000000000000000000000000000000000000001")
	if err != nil {
		t.Fatal(err)
	}
	message := []byte(`{"type":"veto_block","target_experience_id":"exp_1"}`)
	sig, err := key.Sign(message)
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify(key.PublicKeyHex, message, sig); err != nil {
		t.Fatalf("verify: %v", err)
	}
	if err := Verify(key.PublicKeyHex, []byte(`{"type":"tampered"}`), sig); err == nil {
		t.Fatal("expected tampered message verification to fail")
	}
}
