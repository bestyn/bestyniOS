//
//  IAPReceiptValidator.swift
//  neighbourhood
//
//  Created by Artem Korzh on 20.08.2020.
//  Copyright © 2020 GBKSoft. All rights reserved.
//

import Foundation
import StoreKit

enum ReceiptValidationResult {
    case success(ParsedReceipt)
    case error(ReceiptValidationError)
}

enum ReceiptValidationError : Error {
    case couldNotFindReceipt
    case emptyReceiptContents
    case receiptNotSigned
    case appleRootCertificateNotFound
    case receiptSignatureInvalid
    case malformedReceipt
    case malformedInAppPurchaseReceipt
    case incorrectHash
}

struct ParsedReceipt {
    let bundleIdentifier: String?
    let bundleIdData: NSData?
    let appVersion: String?
    let opaqueValue: NSData?
    let sha1Hash: NSData?
    let inAppPurchaseReceipts: [ParsedInAppPurchaseReceipt]?
    let originalAppVersion: String?
    let receiptCreationDate: Date?
    let expirationDate: Date?
}

struct ParsedInAppPurchaseReceipt {
    let quantity: Int?
    let productIdentifier: String?
    let transactionIdentifier: String?
    let originalTransactionIdentifier: String?
    let purchaseDate: Date?
    let originalPurchaseDate: Date?
    let subscriptionExpirationDate: Date?
    let cancellationDate: Date?
    let webOrderLineItemId: Int?
}

class IAPReceiptValidator {

    let receiptExtractor = ReceiptExtractor()
    let receiptSignatureValidator = ReceiptSignatureValidator()
    let receiptParser = ReceiptParser()

    public func validate(receiptData: Data) -> ReceiptValidationResult {
        do {
            let receiptContainer = try receiptExtractor.extractPKCS7Container(receiptData)

            try receiptSignatureValidator.checkSignaturePresence(receiptContainer)
            try receiptSignatureValidator.checkSignatureAuthenticity(receiptContainer)

            let parsedReceipt = try receiptParser.parse(receiptContainer)
            try validateHash(receipt: parsedReceipt)

            return .success(parsedReceipt)
        } catch {
            return .error(error as! ReceiptValidationError)
        }
    }

    private func validateHash(receipt: ParsedReceipt) throws {
        // Make sure that the ParsedReceipt instances has non-nil values needed for hash comparison
        guard let receiptOpaqueValueData = receipt.opaqueValue else { throw ReceiptValidationError.incorrectHash }
        guard let receiptBundleIdData = receipt.bundleIdData else { throw ReceiptValidationError.incorrectHash }
        guard let receiptHashData = receipt.sha1Hash else { throw ReceiptValidationError.incorrectHash }

        guard let deviceIdentifierData = self.deviceIdentifierData() else {
            throw ReceiptValidationError.malformedReceipt
        }

        // Compute the hash for your app & device

        // Set up the hasing context
        var computedHash = Array<UInt8>(repeating: 0, count: 20)
        var sha1Context = SHA_CTX()

        SHA1_Init(&sha1Context)
        SHA1_Update(&sha1Context, deviceIdentifierData.bytes, deviceIdentifierData.length)
        SHA1_Update(&sha1Context, receiptOpaqueValueData.bytes, receiptOpaqueValueData.length)
        SHA1_Update(&sha1Context, receiptBundleIdData.bytes, receiptBundleIdData.length)
        SHA1_Final(&computedHash, &sha1Context)

        let computedHashData = NSData(bytes: &computedHash, length: 20)

        // Compare the computed hash with the receipt's hash
        guard computedHashData.isEqual(to: receiptHashData as Data) else { throw ReceiptValidationError.incorrectHash }
    }

    private func deviceIdentifierData() -> NSData? {
        var deviceIdentifier = UIDevice.current.identifierForVendor?.uuid

        let rawDeviceIdentifierPointer = withUnsafePointer(to: &deviceIdentifier, {
            (unsafeDeviceIdentifierPointer: UnsafePointer<uuid_t?>) -> UnsafeRawPointer in
            return UnsafeRawPointer(unsafeDeviceIdentifierPointer)
        })

        return NSData(bytes: rawDeviceIdentifierPointer, length: 16)
    }
}

struct ReceiptExtractor {
    func extractPKCS7Container(_ receiptData: Data) throws -> UnsafeMutablePointer<PKCS7> {
        let receiptBIO = BIO_new(BIO_s_mem())
        BIO_write(receiptBIO, (receiptData as NSData).bytes, Int32(receiptData.count))
        let receiptPKCS7Container = d2i_PKCS7_bio(receiptBIO, nil)

        guard receiptPKCS7Container != nil else {
            throw ReceiptValidationError.emptyReceiptContents
        }

        let pkcs7DataTypeCode = OBJ_obj2nid(pkcs7_d_sign(receiptPKCS7Container).pointee.contents.pointee.type)

        guard pkcs7DataTypeCode == NID_pkcs7_data else {
            throw ReceiptValidationError.emptyReceiptContents
        }

        return receiptPKCS7Container!
    }
}

struct ReceiptSignatureValidator {
    func checkSignaturePresence(_ PKCS7Container: UnsafeMutablePointer<PKCS7>) throws {
        let pkcs7SignedTypeCode = OBJ_obj2nid(PKCS7Container.pointee.type)

        guard pkcs7SignedTypeCode == NID_pkcs7_signed else {
            throw ReceiptValidationError.receiptNotSigned
        }
    }

    func checkSignatureAuthenticity(_ PKCS7Container: UnsafeMutablePointer<PKCS7>) throws {
        let appleRootCertificateX509 = try loadAppleRootCertificate()

        try verifyAuthenticity(appleRootCertificateX509, PKCS7Container: PKCS7Container)
    }

    fileprivate func loadAppleRootCertificate() throws -> UnsafeMutablePointer<X509> {
        guard
            let appleRootCertificateURL = Bundle.main.url(forResource: "AppleIncRootCertificate", withExtension: "cer"),
            let appleRootCertificateData = try? Data(contentsOf: appleRootCertificateURL)
            else {
                throw ReceiptValidationError.appleRootCertificateNotFound
        }

        let appleRootCertificateBIO = BIO_new(BIO_s_mem())
        BIO_write(appleRootCertificateBIO, (appleRootCertificateData as NSData).bytes, Int32(appleRootCertificateData.count))
        let appleRootCertificateX509 = d2i_X509_bio(appleRootCertificateBIO, nil)

        return appleRootCertificateX509!
    }

    fileprivate func verifyAuthenticity(_ x509Certificate: UnsafeMutablePointer<X509>, PKCS7Container: UnsafeMutablePointer<PKCS7>) throws {
        let x509CertificateStore = X509_STORE_new()
        X509_STORE_add_cert(x509CertificateStore, x509Certificate)

        OpenSSL_add_all_digests()

        let result = PKCS7_verify(PKCS7Container, nil, x509CertificateStore, nil, nil, 0)

        if result != 1 {
            throw ReceiptValidationError.receiptSignatureInvalid
        }
    }
}

struct ReceiptParser {
    func parse(_ PKCS7Container: UnsafeMutablePointer<PKCS7>) throws -> ParsedReceipt {
        var bundleIdentifier: String?
        var bundleIdData: NSData?
        var appVersion: String?
        var opaqueValue: NSData?
        var sha1Hash: NSData?
        var inAppPurchaseReceipts = [ParsedInAppPurchaseReceipt]()
        var originalAppVersion: String?
        var receiptCreationDate: Date?
        var expirationDate: Date?

        guard let contents = PKCS7Container.pointee.d.sign.pointee.contents, let octets = contents.pointee.d.data else {
            throw ReceiptValidationError.malformedReceipt
        }

        var currentASN1PayloadLocation = UnsafePointer(octets.pointee.data)
        let endOfPayload = currentASN1PayloadLocation!.advanced(by: Int(octets.pointee.length))

        var type = Int32(0)
        var xclass = Int32(0)
        var length = 0

        ASN1_get_object(&currentASN1PayloadLocation, &length, &type, &xclass,Int(octets.pointee.length))

        // Payload must be an ASN1 Set
        guard type == V_ASN1_SET else {
            throw ReceiptValidationError.malformedReceipt
        }

        // Decode Payload
        // Step through payload (ASN1 Set) and parse each ASN1 Sequence within (ASN1 Sets contain one or more ASN1 Sequences)
        while currentASN1PayloadLocation! < endOfPayload {

            // Get next ASN1 Sequence
            ASN1_get_object(&currentASN1PayloadLocation, &length, &type, &xclass, currentASN1PayloadLocation!.distance(to: endOfPayload))

            // ASN1 Object type must be an ASN1 Sequence
            guard type == V_ASN1_SEQUENCE else {
                throw ReceiptValidationError.malformedReceipt
            }

            // Attribute type of ASN1 Sequence must be an Integer
            guard let attributeType = DecodeASN1Integer(startOfInt: &currentASN1PayloadLocation, length: currentASN1PayloadLocation!.distance(to: endOfPayload)) else {
                throw ReceiptValidationError.malformedReceipt
            }

            // Attribute version of ASN1 Sequence must be an Integer
            guard DecodeASN1Integer(startOfInt: &currentASN1PayloadLocation, length: currentASN1PayloadLocation!.distance(to: endOfPayload)) != nil else {
                throw ReceiptValidationError.malformedReceipt
            }

            // Get ASN1 Sequence value
            ASN1_get_object(&currentASN1PayloadLocation, &length, &type, &xclass, currentASN1PayloadLocation!.distance(to: endOfPayload))

            // ASN1 Sequence value must be an ASN1 Octet String
            guard type == V_ASN1_OCTET_STRING else {
                throw ReceiptValidationError.malformedReceipt
            }

            // Decode attributes
            switch attributeType {
            case 2:
                var startOfBundleId = currentASN1PayloadLocation
                bundleIdData = NSData(bytes: startOfBundleId, length: length)
                bundleIdentifier = DecodeASN1String(startOfString: &startOfBundleId, length: length)
            case 3:
                var startOfAppVersion = currentASN1PayloadLocation
                appVersion = DecodeASN1String(startOfString: &startOfAppVersion, length: length)
            case 4:
                let startOfOpaqueValue = currentASN1PayloadLocation
                opaqueValue = NSData(bytes: startOfOpaqueValue, length: length)
            case 5:
                let startOfSha1Hash = currentASN1PayloadLocation
                sha1Hash = NSData(bytes: startOfSha1Hash, length: length)
            case 17:
                var startOfInAppPurchaseReceipt = currentASN1PayloadLocation
                let iapReceipt = try parseInAppPurchaseReceipt(currentInAppPurchaseASN1PayloadLocation: &startOfInAppPurchaseReceipt, payloadLength: length)
                inAppPurchaseReceipts.append(iapReceipt)
            case 12:
                var startOfReceiptCreationDate = currentASN1PayloadLocation
                receiptCreationDate = DecodeASN1Date(startOfDate: &startOfReceiptCreationDate, length: length)
            case 19:
                var startOfOriginalAppVersion = currentASN1PayloadLocation
                originalAppVersion = DecodeASN1String(startOfString: &startOfOriginalAppVersion, length: length)
            case 21:
                var startOfExpirationDate = currentASN1PayloadLocation
                expirationDate = DecodeASN1Date(startOfDate: &startOfExpirationDate, length: length)
            default:
                break
            }

            currentASN1PayloadLocation = currentASN1PayloadLocation?.advanced(by: length)
        }

        return ParsedReceipt(bundleIdentifier: bundleIdentifier,
                             bundleIdData: bundleIdData,
                             appVersion: appVersion,
                             opaqueValue: opaqueValue,
                             sha1Hash: sha1Hash,
                             inAppPurchaseReceipts: inAppPurchaseReceipts,
                             originalAppVersion: originalAppVersion,
                             receiptCreationDate: receiptCreationDate,
                             expirationDate: expirationDate)
    }

    func parseInAppPurchaseReceipt(currentInAppPurchaseASN1PayloadLocation: inout UnsafePointer<UInt8>?, payloadLength: Int) throws -> ParsedInAppPurchaseReceipt {
        var quantity: Int?
        var productIdentifier: String?
        var transactionIdentifier: String?
        var originalTransactionIdentifier: String?
        var purchaseDate: Date?
        var originalPurchaseDate: Date?
        var subscriptionExpirationDate: Date?
        var cancellationDate: Date?
        var webOrderLineItemId: Int?

        let endOfPayload = currentInAppPurchaseASN1PayloadLocation!.advanced(by: payloadLength)
        var type = Int32(0)
        var xclass = Int32(0)
        var length = 0

        ASN1_get_object(&currentInAppPurchaseASN1PayloadLocation, &length, &type, &xclass, payloadLength)

        // Payload must be an ASN1 Set
        guard type == V_ASN1_SET else {
            throw ReceiptValidationError.malformedInAppPurchaseReceipt
        }

        // Decode Payload
        // Step through payload (ASN1 Set) and parse each ASN1 Sequence within (ASN1 Sets contain one or more ASN1 Sequences)
        while currentInAppPurchaseASN1PayloadLocation! < endOfPayload {

            // Get next ASN1 Sequence
            ASN1_get_object(&currentInAppPurchaseASN1PayloadLocation, &length, &type, &xclass, currentInAppPurchaseASN1PayloadLocation!.distance(to: endOfPayload))

            // ASN1 Object type must be an ASN1 Sequence
            guard type == V_ASN1_SEQUENCE else {
                throw ReceiptValidationError.malformedInAppPurchaseReceipt
            }

            // Attribute type of ASN1 Sequence must be an Integer
            guard let attributeType = DecodeASN1Integer(startOfInt: &currentInAppPurchaseASN1PayloadLocation, length: currentInAppPurchaseASN1PayloadLocation!.distance(to: endOfPayload)) else {
                throw ReceiptValidationError.malformedInAppPurchaseReceipt
            }

            // Attribute version of ASN1 Sequence must be an Integer
            guard DecodeASN1Integer(startOfInt: &currentInAppPurchaseASN1PayloadLocation, length: currentInAppPurchaseASN1PayloadLocation!.distance(to: endOfPayload)) != nil else {
                throw ReceiptValidationError.malformedInAppPurchaseReceipt
            }

            // Get ASN1 Sequence value
            ASN1_get_object(&currentInAppPurchaseASN1PayloadLocation, &length, &type, &xclass, currentInAppPurchaseASN1PayloadLocation!.distance(to: endOfPayload))

            // ASN1 Sequence value must be an ASN1 Octet String
            guard type == V_ASN1_OCTET_STRING else {
                throw ReceiptValidationError.malformedInAppPurchaseReceipt
            }

            // Decode attributes
            switch attributeType {
            case 1701:
                var startOfQuantity = currentInAppPurchaseASN1PayloadLocation
                quantity = DecodeASN1Integer(startOfInt: &startOfQuantity , length: length)
            case 1702:
                var startOfProductIdentifier = currentInAppPurchaseASN1PayloadLocation
                productIdentifier = DecodeASN1String(startOfString: &startOfProductIdentifier, length: length)
            case 1703:
                var startOfTransactionIdentifier = currentInAppPurchaseASN1PayloadLocation
                transactionIdentifier = DecodeASN1String(startOfString: &startOfTransactionIdentifier, length: length)
            case 1705:
                var startOfOriginalTransactionIdentifier = currentInAppPurchaseASN1PayloadLocation
                originalTransactionIdentifier = DecodeASN1String(startOfString: &startOfOriginalTransactionIdentifier, length: length)
            case 1704:
                var startOfPurchaseDate = currentInAppPurchaseASN1PayloadLocation
                purchaseDate = DecodeASN1Date(startOfDate: &startOfPurchaseDate, length: length)
            case 1706:
                var startOfOriginalPurchaseDate = currentInAppPurchaseASN1PayloadLocation
                originalPurchaseDate = DecodeASN1Date(startOfDate: &startOfOriginalPurchaseDate, length: length)
            case 1708:
                var startOfSubscriptionExpirationDate = currentInAppPurchaseASN1PayloadLocation
                subscriptionExpirationDate = DecodeASN1Date(startOfDate: &startOfSubscriptionExpirationDate, length: length)
            case 1712:
                var startOfCancellationDate = currentInAppPurchaseASN1PayloadLocation
                cancellationDate = DecodeASN1Date(startOfDate: &startOfCancellationDate, length: length)
            case 1711:
                var startOfWebOrderLineItemId = currentInAppPurchaseASN1PayloadLocation
                webOrderLineItemId = DecodeASN1Integer(startOfInt: &startOfWebOrderLineItemId, length: length)
            default:
                break
            }

            currentInAppPurchaseASN1PayloadLocation = currentInAppPurchaseASN1PayloadLocation!.advanced(by: length)
        }

        return ParsedInAppPurchaseReceipt(quantity: quantity,
                                          productIdentifier: productIdentifier,
                                          transactionIdentifier: transactionIdentifier,
                                          originalTransactionIdentifier: originalTransactionIdentifier,
                                          purchaseDate: purchaseDate,
                                          originalPurchaseDate: originalPurchaseDate,
                                          subscriptionExpirationDate: subscriptionExpirationDate,
                                          cancellationDate: cancellationDate,
                                          webOrderLineItemId: webOrderLineItemId)
    }

    func DecodeASN1Integer(startOfInt intPointer: inout UnsafePointer<UInt8>?, length: Int) -> Int? {
        // These will be set by ASN1_get_object
        var type = Int32(0)
        var xclass = Int32(0)
        var intLength = 0

        ASN1_get_object(&intPointer, &intLength, &type, &xclass, length)

        guard type == V_ASN1_INTEGER else {
            return nil
        }

        let integer = c2i_ASN1_INTEGER(nil, &intPointer, intLength)
        let result = ASN1_INTEGER_get(integer)
        ASN1_INTEGER_free(integer)

        return result
    }

    func DecodeASN1String(startOfString stringPointer: inout UnsafePointer<UInt8>?, length: Int) -> String? {
        // These will be set by ASN1_get_object
        var type = Int32(0)
        var xclass = Int32(0)
        var stringLength = 0

        ASN1_get_object(&stringPointer, &stringLength, &type, &xclass, length)

        if type == V_ASN1_UTF8STRING {
            let mutableStringPointer = UnsafeMutableRawPointer(mutating: stringPointer!)
            return String(bytesNoCopy: mutableStringPointer, length: stringLength, encoding: String.Encoding.utf8, freeWhenDone: false)
        }

        if type == V_ASN1_IA5STRING {
            let mutableStringPointer = UnsafeMutableRawPointer(mutating: stringPointer!)
            return String(bytesNoCopy: mutableStringPointer, length: stringLength, encoding: String.Encoding.ascii, freeWhenDone: false)
        }

        return nil
    }

    func DecodeASN1Date(startOfDate datePointer: inout UnsafePointer<UInt8>?, length: Int) -> Date? {
        // Date formatter code from https://www.objc.io/issues/17-security/receipt-validation/#parsing-the-receipt
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        if let dateString = DecodeASN1String(startOfString: &datePointer, length:length) {
            return dateFormatter.date(from: dateString)
        }

        return nil
    }
}
