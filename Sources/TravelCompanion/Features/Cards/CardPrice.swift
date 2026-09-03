import Foundation

/// Formats and parses card prices stored as integer minor units (e.g. cents).
///
/// A card may carry its own `priceCurrency`; legacy cards fall back to the trip
/// currency. Most ISO 4217 currencies use two minor
/// units, but a few (JPY, KRW, VND, ISK, CLP) use none, so the amount is the
/// minor value as-is. IDR officially has a 2-digit minor unit, but the sen is
/// unused everywhere in practice, so Rupiah amounts are written whole by the
/// agent and users alike and must not be scaled. This keeps the displayed
/// price consistent with the currency without bundling a full
/// currency-clients table into the app.
enum CardPrice {
    /// Currencies whose minor unit is 0 (amount is already the major unit).
    private static let zeroDecimalCurrencies: Set<String> = ["JPY", "KRW", "VND", "ISK", "CLP", "PYG", "UGX", "RWF", "VUV", "XAF", "XOF", "XPF", "BIF", "DJF", "GNF", "KMF", "IDR"]

    static func minorExponent(for currency: String?) -> Int {
        guard let currency else { return 2 }
        return zeroDecimalCurrencies.contains(currency.uppercased()) ? 0 : 2
    }

    /// Returns a display string like "¥60.00" / "￥600" / "60.00 CNY", or nil
    /// when there is no price. Falls back to "<amount> <currency>" when the
    /// currency code has no localized symbol on this device.
    static func format(minor: Int64?, currency: String?) -> String? {
        guard let minor else { return nil }
        let exponent = minorExponent(for: currency)
        let major = Decimal(minor) / pow(10, exponent)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency ?? ""
        if let currency, !currency.isEmpty {
            formatter.currencyCode = currency
        }
        formatter.minimumFractionDigits = exponent
        formatter.maximumFractionDigits = exponent
        if let text = formatter.string(from: major as NSDecimalNumber) {
            return text
        }
        // Fall back to a plain decimal + code if the locale lacks the symbol.
        let plain = NumberFormatter()
        plain.minimumFractionDigits = exponent
        plain.maximumFractionDigits = exponent
        let value = plain.string(from: major as NSDecimalNumber) ?? "\(major)"
        return currency.map { "\(value) \($0)" } ?? value
    }

    /// Parses a user-typed decimal amount into minor units for the currency.
    /// Returns nil for empty or non-numeric input.
    static func minorUnits(from text: String, currency: String?) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let exponent = minorExponent(for: currency)
        // Normalize full-width numerals and common decimal separators.
        let normalized = trimmed
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard let doubleValue = Double(normalized), doubleValue.isFinite, doubleValue >= 0 else { return nil }
        let scale = pow(10.0, Double(exponent))
        let minor = (doubleValue * scale).rounded()
        guard minor <= Double(Int64.max), minor >= 1 else { return nil }
        return Int64(minor)
    }
}
