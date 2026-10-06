public enum ExternalPointerAttribution {
    public static func shouldShowIndicator(
        sourceProcessID: Int64,
        currentProcessID: Int32
    ) -> Bool {
        sourceProcessID > 0 && sourceProcessID != Int64(currentProcessID)
    }
}
