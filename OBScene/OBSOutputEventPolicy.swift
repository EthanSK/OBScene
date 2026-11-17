/// Exact obs-websocket output-event matching for user-facing alerts.
/// Intermediate states and unrelated outputs must not be treated as proof
/// that the stream is live.
enum OBSStreamStartNotificationPolicy {
    static func shouldNotify(
        eventType: String?,
        outputState: String?
    ) -> Bool {
        eventType == "StreamStateChanged"
            && outputState == "OBS_WEBSOCKET_OUTPUT_STARTED"
    }
}
