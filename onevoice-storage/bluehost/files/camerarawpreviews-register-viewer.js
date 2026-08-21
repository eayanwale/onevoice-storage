/**
 * Replacement for camerarawpreviews/js/register-viewer.js
 *
 * The stock file registers its Viewer handler inside a bare
 *   if (OCA.Viewer && typeof OCA.Viewer.registerHandler === 'function') { ... }
 * guard, and is loaded by Util::addInitScript as a DEFERRED CLASSIC script.
 * The Viewer app's own bundle is an ES MODULE loaded later in the document.
 * Deferred classic scripts and module scripts execute in document order, so
 * this file runs ~19 scripts before OCA.Viewer exists — the guard is always
 * false, the handler is never registered, and clicking a RAW file falls
 * through to a plain download instead of opening the viewer.
 *
 * Fix: poll until OCA.Viewer appears, then register. The registration logic
 * below is identical to the patch running on the EC2 instance since
 * 2026-07-18 (this header comment is the only addition).
 *
 * NOTE: camerarawpreviews is a signed app, so replacing this file makes
 * `occ integrity:check-app camerarawpreviews` report INVALID_HASH. That is
 * expected and matches EC2. An app update overwrites this file and silently
 * restores the broken behaviour — configure.sh re-applies it on every run.
 */
(function() {
    function registerRawViewer() {
        if (typeof OCA === "undefined" || !OCA.Viewer || typeof OCA.Viewer.registerHandler !== "function") {
            return false;
        }
        OCA.Viewer.registerHandler({
            id: "camerarawpreviews",
            group: "media",
            mimes: ["image/x-dcraw"],
            component: {
                name: "RAWViewer",
                props: {
                    fileid: { type: Number, default: null },
                    filename: { type: String, default: null },
                    basename: { type: String, default: null },
                    source: { type: String, default: null },
                    davPath: { type: String, default: null },
                    mime: { type: String, default: null },
                    permissions: { type: String, default: null },
                },
                template: "<img :src=\"previewUrl\" :alt=\"filename\" style=\"max-width:100%;max-height:100%;object-fit:contain;\" />",
                computed: {
                    previewUrl: function() {
                        if (this.fileid) {
                            return OC.generateUrl("/core/preview?fileId=" + this.fileid + "&x=4096&y=4096&a=true");
                        }
                        return this.davPath || "";
                    }
                }
            }
        });
        console.log("CameraRAW Previews: registered with Viewer");
        return true;
    }
    if (!registerRawViewer()) {
        var attempts = 0;
        var interval = setInterval(function() {
            attempts++;
            if (registerRawViewer() || attempts > 50) {
                clearInterval(interval);
            }
        }, 200);
    }
})();
