// This file is copied into the patched dependency before its tests run.
package jshttp

import (
	"context"
	"errors"
	"testing"

	"github.com/mxschmitt/playwright-go"
)

var errPatchedRuntimeUnavailable = errors.New("patched runtime unavailable")

type patchedPlaywrightPageStub struct {
	playwright.Page
	closed bool
}

func (p *patchedPlaywrightPageStub) IsClosed() bool {
	return p.closed
}

type patchedSlotPage struct{}

func (p *patchedSlotPage) isClosed() bool {
	return false
}

type patchedSlotRuntime struct {
	page           page
	browserError   error
	browserRebuild int
}

func (r *patchedSlotRuntime) pageCount() int {
	if r.page == nil {
		return 0
	}

	return 1
}

func (r *patchedSlotRuntime) closeExtraPages() error {
	return nil
}

func (r *patchedSlotRuntime) closeBrowser() error {
	return nil
}

func (r *patchedSlotRuntime) primaryPage() (page, error) {
	if r.page == nil {
		return nil, errPatchedRuntimeUnavailable
	}

	return r.page, nil
}

func (r *patchedSlotRuntime) recreatePage() error {
	return errPatchedRuntimeUnavailable
}

func (r *patchedSlotRuntime) recreateContext() error {
	return errPatchedRuntimeUnavailable
}

func (r *patchedSlotRuntime) recreateBrowser() error {
	r.browserRebuild++
	if r.browserError != nil {
		return r.browserError
	}

	r.page = &patchedSlotPage{}
	return nil
}

func (r *patchedSlotRuntime) recycleIfNeeded() error {
	return nil
}

func TestPatchedPlaywrightPageClosedState(t *testing.T) {
	t.Parallel()

	for _, testCase := range []struct {
		name   string
		closed bool
	}{
		{name: "open", closed: false},
		{name: "closed", closed: true},
	} {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()

			wrappedPage := &playwrightPage{
				p: &patchedPlaywrightPageStub{closed: testCase.closed},
			}
			if got := wrappedPage.isClosed(); got != testCase.closed {
				t.Fatalf("isClosed() = %t, want %t", got, testCase.closed)
			}
		})
	}
}

func TestPatchedSessionSlotReturnsPageAfterBrowserRebuild(t *testing.T) {
	t.Parallel()

	runtime := &patchedSlotRuntime{}
	slot := &sessionSlot{runtime: runtime}

	got, err := slot.acquirePage(context.Background())
	if err != nil {
		t.Fatalf("acquirePage() error = %v", err)
	}
	if got == nil {
		t.Fatal("acquirePage() returned a nil page after a successful browser rebuild")
	}
	if runtime.browserRebuild != 1 {
		t.Fatalf("recreateBrowser() calls = %d, want 1", runtime.browserRebuild)
	}
}

func TestPatchedSessionSlotReturnsBrowserRebuildError(t *testing.T) {
	t.Parallel()

	want := errors.New("browser rebuild failed")
	runtime := &patchedSlotRuntime{browserError: want}
	slot := &sessionSlot{runtime: runtime}

	got, err := slot.acquirePage(context.Background())
	if got != nil {
		t.Fatalf("acquirePage() page = %v, want nil", got)
	}
	if !errors.Is(err, want) {
		t.Fatalf("acquirePage() error = %v, want %v", err, want)
	}
}
