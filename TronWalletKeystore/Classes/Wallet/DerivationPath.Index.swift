
import Foundation

extension DerivationPath {
    /// Derivation path index.
    public struct Index: Hashable, CustomStringConvertible {
        /// Index value.
        public var value: Int

        /// Whether the index is hardened.
        public var hardened: Bool

        /// The derivation index.
        public var derivationIndex: UInt32 {
            if hardened {
                return UInt32(value) | 0x80000000
            } else {
                return UInt32(value)
            }
        }

        public init(_ value: Int, hardened: Bool = true) {
            self.value = value
            self.hardened = hardened
        }

        public var hashValue: Int {
            return value.hashValue ^ hardened.hashValue
        }

        public static func == (lhs: Index, rhs: Index) -> Bool {
            return lhs.value == rhs.value && lhs.hardened == rhs.hardened
        }

        public var description: String {
            if hardened {
                return "\(value)'"
            } else {
                return value.description
            }
        }
    }
}
