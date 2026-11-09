#if !SHEPHERD_LEGACY_FIXTURES
/// Deferred integrations have no implementation or opt-in path in the product.
/// Historical settings/data are neither read for authority nor removed.
enum ShepherdBrowserFeature {
    static let isAvailable = false
    static let preferenceKey = "experimentalShepherdBrowserEnabled"
}
#endif
