import CoreLocation
import MapKit

/// The user's area for weather and disaster info: searched by name (with suggestions) or
/// taken once from the current location. Location is read only when asked, never tracked.
@MainActor
final class PlaceService: NSObject, ObservableObject, MKLocalSearchCompleterDelegate, CLLocationManagerDelegate {
    struct Suggestion: Identifiable, Hashable {
        var id: String { title + "|" + subtitle }
        let title: String
        let subtitle: String
    }

    @Published var query = "" { didSet { completer.queryFragment = query } }
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var isLocating = false
    @Published var error: String?

    private let completer = MKLocalSearchCompleter()
    private let manager = CLLocationManager()
    private let settings: AppSettings
    private let onChange: () -> Void

    init(settings: AppSettings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
        completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.2, longitude: 138.25),
                                              span: MKCoordinateSpan(latitudeDelta: 22, longitudeDelta: 25))
        manager.delegate = self
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results.prefix(6).map { Suggestion(title: $0.title, subtitle: $0.subtitle) }
        Task { @MainActor in self.suggestions = Array(results) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}

    /// Resolves a suggestion (or free text) to a place.
    func choose(_ text: String) async {
        error = nil
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = text
        guard let item = try? await MKLocalSearch(request: req).start().mapItems.first else {
            error = "「\(text)」が見つかりませんでした"
            return
        }
        await apply(item.placemark.location ?? CLLocation(latitude: item.placemark.coordinate.latitude,
                                                          longitude: item.placemark.coordinate.longitude))
        query = ""
        suggestions = []
    }

    func useCurrentLocation() {
        error = nil
        isLocating = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            isLocating = false
            error = "位置情報が許可されていません。"
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isLocating else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorized: manager.requestLocation()
            case .denied, .restricted:
                self.isLocating = false
                self.error = "位置情報が許可されませんでした"
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            await self.apply(loc)
            self.isLocating = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.isLocating = false
            self.error = "現在地を取得できませんでした"
        }
    }

    /// Names the place (市区町村 + 都道府県) by reverse geocoding, then saves it.
    private func apply(_ loc: CLLocation) async {
        let mark = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "ja_JP")).first
        settings.weatherLatitude = loc.coordinate.latitude
        settings.weatherLongitude = loc.coordinate.longitude
        settings.weatherPlace = mark?.locality ?? mark?.subAdministrativeArea ?? mark?.administrativeArea ?? "指定した地点"
        if let pref = mark?.administrativeArea { settings.weatherPrefecture = pref }
        onChange()
    }
}
