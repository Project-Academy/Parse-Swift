//
//  ParseAuthenticationAsyncTests.swift
//  ParseSwift
//
//  Created by Corey Baker on 9/28/21.
//  Copyright © 2021 Network Reconnaissance Lab. All rights reserved.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ParseSwift
#if canImport(Combine)
import Combine
#endif

class ParseAuthenticationAsyncTests: XCTestCase {
    struct User: ParseUser {

        //: These are required by ParseObject
        var objectId: String?
        var createdAt: Date?
        var updatedAt: Date?
        var ACL: ParseACL?
        var originalData: Data?

        // These are required by ParseUser
        var username: String?
        var email: String?
        var emailVerified: Bool?
        var password: String?
        var authData: [String: [String: String]?]?
    }

    struct LoginSignupResponse: ParseUser {

        var objectId: String?
        var createdAt: Date?
        var sessionToken: String
        var updatedAt: Date?
        var ACL: ParseACL?
        var originalData: Data?

        // These are required by ParseUser
        var username: String?
        var email: String?
        var emailVerified: Bool?
        var password: String?
        var authData: [String: [String: String]?]?

        // Your custom keys
        var customKey: String?

        init() {
            let date = Date()
            self.createdAt = date
            self.updatedAt = date
            self.objectId = "yarr"
            self.ACL = nil
            self.customKey = "blah"
            self.sessionToken = "myToken"
            self.username = "hello10"
            self.email = "hello@parse.com"
        }
    }

    struct TestAuth<AuthenticatedUser: ParseUser>: ParseAuthentication {
        static var __type: String { // swiftlint:disable:this identifier_name
            "test"
        }
        func login(authData: [String: String],
                   options: API.Options,
                   callbackQueue: DispatchQueue,
                   completion: @escaping (Result<AuthenticatedUser, ParseError>) -> Void) {
            let error = ParseError(code: .otherCause, message: "Not implemented")
            completion(.failure(error))
        }

        func link(authData: [String: String],
                  options: API.Options,
                  callbackQueue: DispatchQueue,
                  completion: @escaping (Result<AuthenticatedUser, ParseError>) -> Void) {
            let error = ParseError(code: .otherCause, message: "Not implemented")
            completion(.failure(error))
        }

        #if canImport(Combine)
        func loginPublisher(authData: [String: String],
                            options: API.Options) -> Future<AuthenticatedUser, ParseError> {
            let error = ParseError(code: .otherCause, message: "Not implemented")
            return Future { promise in
                promise(.failure(error))
            }
        }

        func linkPublisher(authData: [String: String],
                           options: API.Options) -> Future<AuthenticatedUser, ParseError> {
            let error = ParseError(code: .otherCause, message: "Not implemented")
            return Future { promise in
                promise(.failure(error))
            }
        }
        #endif

        func login(authData: [String: String],
                   options: API.Options) async throws -> AuthenticatedUser {
            throw ParseError(code: .otherCause, message: "Not implemented")
        }

        func link(authData: [String: String],
                  options: API.Options) async throws -> AuthenticatedUser {
            throw ParseError(code: .otherCause, message: "Not implemented")
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        guard let url = URL(string: "http://localhost:1337/parse") else {
            XCTFail("Should create valid URL")
            return
        }
        try await ParseSwift.initialize(applicationId: "applicationId",
                                        clientKey: "clientKey",
                                        primaryKey: "primaryKey",
                                        serverURL: url,
                                        testing: true)

    }

    override func tearDown() async throws {
        try await super.tearDown()
        MockURLProtocol.removeAll()
        #if !os(Linux) && !os(Android) && !os(Windows)
        try await KeychainStore.shared.deleteAll()
        #endif
        try await ParseStorage.shared.deleteAll()
    }

    @MainActor
    func testLogin() async throws {

        var serverResponse = LoginSignupResponse()
        let authData = ParseAnonymous<User>.AuthenticationKeys.id.makeDictionary()
        let type = TestAuth<User>.__type
        serverResponse.username = "hello"
        serverResponse.password = "world"
        serverResponse.objectId = "yarr"
        serverResponse.sessionToken = "myToken"
        serverResponse.authData = [type: authData]
        serverResponse.createdAt = Date()
        serverResponse.updatedAt = serverResponse.createdAt?.addingTimeInterval(+300)

        var userOnServer: User!

        let encoded: Data!
        do {
            encoded = try serverResponse.getEncoder().encode(serverResponse, skipKeys: .none)
            // Get dates in correct format from ParseDecoding strategy
            userOnServer = try serverResponse.getDecoder().decode(User.self, from: encoded)
        } catch {
            XCTFail("Should encode/decode. Error \(error)")
            return
        }
        MockURLProtocol.mockRequests { _ in
            return MockURLResponse(data: encoded, statusCode: 200)
        }

        let user = try await User.login(type, authData: ["id": "yolo"])
        let currentUser = try await User.current()
        XCTAssertEqual(user, currentUser)
        XCTAssertEqual(user, userOnServer)
        XCTAssertEqual(user.username, "hello")
        XCTAssertEqual(user.password, "world")
        XCTAssertEqual(user.authData, serverResponse.authData)
    }

    @MainActor
    func loginNormally() async throws -> User {
        let loginResponse = LoginSignupResponse()

        MockURLProtocol.mockRequests { _ in
            do {
                let encoded = try loginResponse.getEncoder().encode(loginResponse, skipKeys: .none)
                return MockURLResponse(data: encoded, statusCode: 200)
            } catch {
                return nil
            }
        }
        return try await User.login(username: "parse", password: "user")
    }

    @MainActor
    func testLink() async throws {

        _ = try await loginNormally()
        MockURLProtocol.removeAll()

        let type = TestAuth<User>.__type
        var serverResponse = LoginSignupResponse()
        serverResponse.updatedAt = Date()

        var userOnServer: User!

        let encoded: Data!
        do {
            encoded = try serverResponse.getEncoder().encode(serverResponse, skipKeys: .none)
            // Get dates in correct format from ParseDecoding strategy
            userOnServer = try serverResponse.getDecoder().decode(User.self, from: encoded)
        } catch {
            XCTFail("Should encode/decode. Error \(error)")
            return
        }
        MockURLProtocol.mockRequests { _ in
            return MockURLResponse(data: encoded, statusCode: 200)
        }

        let user = try await User.link(type, authData: ["id": "yolo"])
        let currentUser = try await User.current()
        XCTAssertEqual(user, currentUser)
        XCTAssertEqual(user.updatedAt, userOnServer.updatedAt)
        XCTAssertEqual(user.username, "hello10")
        XCTAssertNil(user.password)
    }

}
