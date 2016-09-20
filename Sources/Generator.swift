//
//  Generator.swift
//  OneTimePassword
//
//  Copyright (c) 2014-2016 Matt Rubin and the OneTimePassword authors
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

/// A `Generator` contains all of the parameters needed to generate a one-time password.
public struct Generator: Equatable {
    /// The moving factor, either timer- or counter-based.
    public let factor: Factor

    /// The secret shared between the client and server.
    public let secret: Data

    /// The cryptographic hash function used to generate the password.
    public let algorithm: Algorithm

    /// The number of digits in the password.
    public let digits: Int

    /// Initializes a new password generator with the given parameters.
    ///
    /// - parameter factor:    The moving factor
    /// - parameter secret:    The shared secret
    /// - parameter algorithm: The cryptographic hash function
    /// - parameter digits:    The number of digits in the password
    ///
    /// - returns: A new password generator with the given parameters, or `nil` if the parameters
    ///            are invalid.
    public init?(factor: Factor, secret: Data, algorithm: Algorithm, digits: Int) {
        guard Generator.validateFactor(factor) && Generator.validateDigits(digits) else {
            return nil
        }
        self.factor = factor
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
    }

    // MARK: Password Generation

    /// Generates the password for the given point in time.
    ///
    /// - parameter time: The target time, as seconds since the Unix epoch.
    ///                   The time value must be positive.
    ///
    /// - throws: A `Generator.Error` if a valid password cannot be generated for the given time.
    /// - returns: The generated password, or throws an error if a password could not be generated.
    public func passwordAtTime(_ time: TimeInterval) throws -> String {
        guard Generator.validateDigits(digits) else {
            throw Error.invalidDigits
        }

        let counter = try factor.counterAtTime(time)
        // Ensure the counter value is big-endian
        var bigCounter = counter.bigEndian

        // Generate an HMAC value from the key and counter
        let counterData = withUnsafePointer(&bigCounter) {
            Data(bytes: UnsafePointer<UInt8>($0), count: sizeof(UInt64.self))
        }
        let hash = HMAC(algorithm, key: secret, data: counterData)

        var truncatedHash = hash.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) -> UInt32 in
            // Use the last 4 bits of the hash as an offset (0 <= offset <= 15)
            let offset = ptr[hash.count-1] & 0x0f

            // Take 4 bytes from the hash, starting at the given byte offset
            let truncatedHashPtr = ptr + Int(offset)
            let truncatedHash = UnsafePointer<UInt32>(truncatedHashPtr).pointee
            return truncatedHash
        }

        // Ensure the four bytes taken from the hash match the current endian format
        truncatedHash = UInt32(bigEndian: truncatedHash)
        // Discard the most significant bit
        truncatedHash &= 0x7fffffff
        // Constrain to the right number of digits
        truncatedHash = truncatedHash % UInt32(pow(10, Float(digits)))

        // Pad the string representation with zeros, if necessary
        return String(truncatedHash).paddedWithCharacter("0", toLength: digits)
    }

    // MARK: Update

    /// Returns a `Generator` configured to generate the *next* password, which follows the password
    /// generated by `self`.
    ///
    /// - requires: The next generator is valid.
    public func successor() -> Generator {
        switch factor {
        case .counter(let counter):
            // Update a counter-based generator by incrementing the counter. Force-unwrapping should
            // be safe here, since any valid generator should have a valid successor.
            let nextGenerator = Generator(
                factor: .counter(counter + 1),
                secret: secret,
                algorithm: algorithm,
                digits: digits
            )
            return nextGenerator!
        case .timer:
            // A timer-based generator does not need to be updated.
            return self
        }
    }

    // MARK: Nested Types

    /// A moving factor with which a generator produces different one-time passwords over time.
    /// The possible values are `Counter` and `Timer`, with associated values for each.
    public enum Factor: Equatable {
        /// Indicates a HOTP, with an associated 8-byte counter value for the moving factor. After
        /// each use of the password generator, the counter should be incremented to stay in sync
        /// with the server.
        case counter(UInt64)
        /// Indicates a TOTP, with an associated time interval for calculating the time-based moving
        /// factor. This period value remains constant, and is used as a divisor for the number of
        /// seconds since the Unix epoch.
        case timer(period: TimeInterval)

        /// Calculates the counter value for the moving factor at the target time. For a counter-
        /// based factor, this will be the associated counter value, but for a timer-based factor,
        /// it will be the number of time steps since the Unix epoch, based on the associated
        /// period value.
        ///
        /// - parameter time: The target time, as seconds since the Unix epoch.
        ///
        /// - throws: A `Generator.Error` if a valid counter cannot be calculated.
        /// - returns: The counter value needed to generate the password for the target time.
        private func counterAtTime(_ time: TimeInterval) throws -> UInt64 {
            switch self {
            case .counter(let counter):
                return counter
            case .timer(let period):
                guard Generator.validateTime(time) else {
                    throw Error.invalidTime
                }
                guard Generator.validatePeriod(period) else {
                    throw Error.invalidPeriod
                }
                return UInt64(time / period)
            }
        }
    }

    /// A cryptographic hash function used to calculate the HMAC from which a password is derived.
    /// The supported algorithms are SHA-1, SHA-256, and SHA-512
    public enum Algorithm: Equatable {
        /// The SHA-1 hash function
        case SHA1
        /// The SHA-256 hash function
        case SHA256
        /// The SHA-512 hash function
        case SHA512
    }

    /// An error type enum representing the various errors a `Generator` can throw when computing a
    /// password.
    public enum Error: ErrorProtocol {
        /// The requested time is before the epoch date.
        case invalidTime
        /// The timer period is not a positive number of seconds
        case invalidPeriod
        /// The number of digits is either too short to be secure, or too long to compute.
        case invalidDigits
    }
}

/// Compares two `Generator`s for equality.
public func == (lhs: Generator, rhs: Generator) -> Bool {
    return (lhs.factor == rhs.factor)
        && (lhs.algorithm == rhs.algorithm)
        && (lhs.secret == rhs.secret)
        && (lhs.digits == rhs.digits)
}

/// Compares two `Factor`s for equality.
public func == (lhs: Generator.Factor, rhs: Generator.Factor) -> Bool {
    switch (lhs, rhs) {
    case let (.counter(l), .counter(r)):
        return l == r
    case let (.timer(l), .timer(r)):
        return l == r
    default:
        return false
    }
}

// MARK: - Private

private extension Generator {
    // MARK: Validation

    private static func validateDigits(_ digits: Int) -> Bool {
        // https://tools.ietf.org/html/rfc4226#section-5.3 states "Implementations MUST extract a
        // 6-digit code at a minimum and possibly 7 and 8-digit codes."
        let acceptableDigits = 6...8
        return acceptableDigits.contains(digits)
    }

    private static func validateFactor(_ factor: Factor) -> Bool {
        switch factor {
        case .counter:
            return true
        case .timer(let period):
            return validatePeriod(period)
        }
    }

    private static func validatePeriod(_ period: TimeInterval) -> Bool {
        // The period must be positive and non-zero to produce a valid counter value.
        return (period > 0)
    }

    private static func validateTime(_ time: TimeInterval) -> Bool {
        // The time must be positive to produce a valid counter value.
        return (time >= 0)
    }
}

private extension String {
    /// Prepends the given character to the beginning of `self` until it matches the given length.
    func paddedWithCharacter(_ character: Character, toLength length: Int) -> String {
        let paddingCount = length - characters.count
        guard paddingCount > 0 else { return self }

        let padding = String(repeating: character, count: paddingCount)
        return padding + self
    }
}
