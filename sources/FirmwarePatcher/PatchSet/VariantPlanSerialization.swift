import Foundation

// Preserve the existing wire fields while making the set representation stable.
// Decoding a plan does not establish VM/input/catalog binding or execution authority.
extension VariantPlanResolver.VariantPlan {
    private enum CodingKeys: String, CodingKey {
        case variant, gates, upstreamTag, selected, excludedByVersion, excludedByOptIn
        case excludedByVariant, guestUncovered, notImplemented, enabledSteps
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(variant, forKey: .variant)
        try values.encode(gates, forKey: .gates)
        try values.encode(upstreamTag, forKey: .upstreamTag)
        try values.encode(selected, forKey: .selected)
        try values.encode(excludedByVersion, forKey: .excludedByVersion)
        try values.encode(excludedByOptIn, forKey: .excludedByOptIn)
        try values.encode(excludedByVariant, forKey: .excludedByVariant)
        try values.encode(guestUncovered, forKey: .guestUncovered)
        try values.encode(notImplemented, forKey: .notImplemented)
        try values.encode(enabledSteps.sorted(), forKey: .enabledSteps)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let steps = try values.decode([String].self, forKey: .enabledSteps)
        guard Set(steps).count == steps.count else {
            throw DecodingError.dataCorruptedError(forKey: .enabledSteps, in: values,
                debugDescription: "Repeated enabledSteps are not a valid frozen plan")
        }
        self.init(
            variant: try values.decode(String.self, forKey: .variant),
            gates: try values.decode(PatchGateSnapshot.self, forKey: .gates),
            upstreamTag: try values.decode(String.self, forKey: .upstreamTag),
            selected: try values.decode([VariantPlanResolver.Entry].self, forKey: .selected),
            excludedByVersion: try values.decode([VariantPlanResolver.Entry].self, forKey: .excludedByVersion),
            excludedByOptIn: try values.decode([VariantPlanResolver.Entry].self, forKey: .excludedByOptIn),
            excludedByVariant: try values.decode([VariantPlanResolver.Entry].self, forKey: .excludedByVariant),
            guestUncovered: try values.decode([VariantPlanResolver.Entry].self, forKey: .guestUncovered),
            notImplemented: try values.decode([VariantPlanResolver.Entry].self, forKey: .notImplemented),
            enabledSteps: Set(steps))
    }
}
