import Foundation

/**
 Objects that conform to the `ParseUser` protocol have a local representation of a user persisted to the
 Keychain and Parse Server. This protocol inherits from the `ParseObject` protocol, and retains the same
 functionality of a `ParseObject`, but also extends it with various user specific methods, like
 authentication, signing up, and validation uniqueness.
*/
public protocol ParseUser: ParseObject {
    /**
    The username for the `ParseUser`.
    */
    var username: String? { get set }

    /**
    The email for the `ParseUser`.
    */
    var email: String? { get set }

    /**
    Determines if the email is verified for the `ParseUser`.
     - note: This value can only be changed on the Parse Server.
    */
    var emailVerified: Bool? { get }

    /**
     The password for the `ParseUser`.

     This will not be filled in from the server with the password.
     It is only meant to be set.
    */
    var password: String? { get set }

    /**
     The authentication data for the `ParseUser`. Used by `ParseAnonymous`
     or any authentication type that conforms to `ParseAuthentication`.
    */
    var authData: [String: [String: String]?]? { get set }
}

// MARK: Default Implementations
public extension ParseUser {
    static var className: String {
        "_User"
    }

    func mergeParse(with object: Self) throws -> Self {
        guard hasSameObjectId(as: object) else {
            throw ParseError(code: .otherCause,
                             message: "objectId's of objects do not match")
        }
        var updatedUser = self
        if shouldRestoreKey(\.ACL,
                             original: object) {
            updatedUser.ACL = object.ACL
        }
        if shouldRestoreKey(\.username,
                             original: object) {
            updatedUser.username = object.username
        }
        if shouldRestoreKey(\.email,
                             original: object) {
            updatedUser.email = object.email
        }
        if shouldRestoreKey(\.authData,
                             original: object) {
            updatedUser.authData = object.authData
        }
        return updatedUser
    }

    func merge(with object: Self) throws -> Self {
        do {
            return try mergeAutomatically(object)
        } catch {
            return try mergeParse(with: object)
        }
    }

    /**
     The session token for the `ParseUser`.

     This is set by the server upon successful authentication.
    */
    static func sessionToken() async throws -> String {
        guard let sessionToken = await Self.currentContainer()?.sessionToken else {
            throw ParseError(code: .otherCause,
                             message: "Missing sessionToken, be sure you are logged in")
        }
        return sessionToken
    }
}

// MARK: Convenience
extension ParseUser {
    var endpoint: API.Endpoint {
        if let objectId = objectId {
            return .user(objectId: objectId)
        }

        return .users
    }

    func endpoint(_ method: API.Method) -> API.Endpoint {
        if !Parse.configuration.isRequiringCustomObjectIds || method != .POST {
            return endpoint
        } else {
            return .users
        }
    }

    static func deleteCurrentKeychain() async {
        await deleteCurrentContainerFromKeychain()
        await BaseParseInstallation.deleteCurrentContainerFromKeychain()
        await ParseACL.deleteDefaultFromKeychain()
        await BaseConfig.deleteCurrentContainerFromKeychain()
        clearCache()
    }
}

// MARK: CurrentUserContainer
struct CurrentUserContainer<T: ParseUser>: Codable, Hashable {
    var currentUser: T?
    var sessionToken: String?
}

// MARK: Current User Support
public extension ParseUser {
    internal static func currentContainer() async -> CurrentUserContainer<Self>? {
        guard let currentUserInMemory: CurrentUserContainer<Self>
                = try? await ParseStorage.shared.get(valueFor: ParseStorage.Keys.currentUser) else {
            #if !os(Linux) && !os(Android) && !os(Windows)
            return try? await KeychainStore.shared.get(valueFor: ParseStorage.Keys.currentUser)
            #else
            return nil
            #endif
        }
        return currentUserInMemory
    }

    internal static func setCurrentContainer(_ newValue: CurrentUserContainer<Self>?) async {
        var currentContainer = newValue
        currentContainer?.currentUser?.originalData = nil
        try? await ParseStorage.shared.set(currentContainer, for: ParseStorage.Keys.currentUser)
        #if !os(Linux) && !os(Android) && !os(Windows)
        try? await KeychainStore.shared.set(currentContainer, for: ParseStorage.Keys.currentUser)
        #endif
    }

    internal static func deleteCurrentContainerFromKeychain() async {
        try? await ParseStorage.shared.delete(valueFor: ParseStorage.Keys.currentUser)
        #if !os(Linux) && !os(Android) && !os(Windows)
        await URLSession.liveQuery.closeAll()
        try? await KeychainStore.shared.delete(valueFor: ParseStorage.Keys.currentUser)
        #endif
        await Self.setCurrentContainer(nil)
    }

    /**
     Gets the currently logged in user and returns an instance of it.

     - returns: Returns a `ParseUser` that is the currently logged in user. If there is none, throws an error.
     - throws: An error of `ParseError` type.
    */
    static func current() async throws -> Self {
        await yieldIfNotInitialized()
        guard let container = await Self.currentContainer(),
              let user = container.currentUser else {
            throw ParseError(code: .otherCause,
                             message: "There is no current user logged in")
        }
        return user
    }

    internal static func setCurrent(_ newValue: Self?) async throws {
        var currentContainer = await Self.currentContainer()
        if let newValue = newValue,
            let currentUser = currentContainer?.currentUser {
            guard currentUser.hasSameObjectId(as: newValue) else {
                throw ParseError(code: .otherCause, message: "objectId's must match to update current user")
            }
        }
        currentContainer?.currentUser = newValue
        await Self.setCurrentContainer(currentContainer)
    }
}

// MARK: SignupLoginBody
struct SignupLoginBody: ParseEncodable {
    var username: String?
    var password: String?
    var authData: [String: [String: String]?]?

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    init(authData: [String: [String: String]?]) {
        self.authData = authData
    }
}

// MARK: EmailBody
struct EmailBody: ParseEncodable {
    let email: String
}

// MARK: Logging In
extension ParseUser {

    /**
     Makes an *asynchronous* request to log in a user with specified credentials.
     Returns an instance of the successfully logged in `ParseUser`.

     This also caches the user locally so that calls to *current* will use the latest logged in user.
     - parameter username: The username of the user.
     - parameter password: The password of the user.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    public static func login(
        username: String,
        password: String,
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<Self, ParseError>) -> Void
    ) {
        Task {
            var options = options
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            await loginCommand(username: username, password: password)
                .execute(options: options,
                              callbackQueue: callbackQueue,
                              completion: completion)
        }
    }

    internal static func loginCommand(username: String,
                                      password: String) -> API.Command<SignupLoginBody, Self> {

        let body = SignupLoginBody(username: username, password: password)
        return API.Command<SignupLoginBody, Self>(method: .POST,
                                                  path: .login,
                                                  body: body) { (data) async throws -> Self in
            let sessionToken = try ParseCoding.jsonDecoder().decode(LoginSignupResponse.self, from: data).sessionToken
            let user = try ParseCoding.jsonDecoder().decode(Self.self, from: data)

            await Self.setCurrentContainer(.init(
                currentUser: user,
                sessionToken: sessionToken
            ))
            return user
        }
    }

    /**
     Logs in a `ParseUser` *asynchronously* with a session token. On success, this saves the logged in
     `ParseUser`with this session to the keychain, so you can retrieve the currently logged in user using
     *current*.

     - parameter sessionToken: The sessionToken of the user to login.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default
     value of .main.
     - parameter completion: The block to execute when completed.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    public func become(sessionToken: String,
                       options: API.Options = [],
                       callbackQueue: DispatchQueue = .main,
                       completion: @escaping (Result<Self, ParseError>) -> Void) {
        Self.become(sessionToken: sessionToken,
                    options: options,
                    callbackQueue: callbackQueue,
                    completion: completion)
    }

    /**
     Logs in a `ParseUser` *asynchronously* with a session token. On success, this saves the logged in
     `ParseUser`with this session to the keychain, so you can retrieve the currently logged in user using
     *current*.

     - parameter sessionToken: The sessionToken of the user to login.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default
     value of .main.
     - parameter completion: The block to execute when completed.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    public static func become(sessionToken: String,
                              options: API.Options = [],
                              callbackQueue: DispatchQueue = .main,
                              completion: @escaping (Result<Self, ParseError>) -> Void) {
        Task {
            var newUser = Self()
            newUser.objectId = "me"
            var options = options
            options.insert(.sessionToken(sessionToken))
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            do {
                try await newUser.meCommand(sessionToken: sessionToken)
                    .execute(options: options,
                                  callbackQueue: callbackQueue,
                                  completion: completion)
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

#if !os(Linux) && !os(Android) && !os(Windows)
    /**
     Logs in a `ParseUser` *asynchronously* using the session token from the Parse Objective-C SDK Keychain.
     Returns an instance of the successfully logged in `ParseUser`. The Parse Objective-C SDK Keychain is not
     modified in any way when calling this method; allowing developers to revert their applications back to the older
     SDK if desired.

     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default
     value of .main.
     - parameter completion: The block to execute when completed.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
     - warning: When initializing the Swift SDK, `migratingFromObjcSDK` should be set to **false**
     when calling this method.
     - warning: The latest **PFUser** from the Objective-C SDK should be saved to your
     Parse Server before calling this method.
    */
    public static func loginUsingObjCKeychain(options: API.Options = [],
                                              callbackQueue: DispatchQueue = .main,
                                              completion: @escaping (Result<Self, ParseError>) -> Void) {
        Task {
            let objcParseKeychain = KeychainStore.objectiveC
            // swiftlint:disable:next line_length
            guard let objcParseUser: [String: String] = await objcParseKeychain?.objectObjectiveC(forKey: "currentUser"),
                  let sessionToken: String = objcParseUser["sessionToken"] ??
                    objcParseUser["session_token"] else {
                let error = ParseError(code: .otherCause,
                                       message: "Could not find a session token in the Parse Objective-C SDK Keychain.")
                callbackQueue.async {
                    completion(.failure(error))
                }
                return
            }

            guard let currentContainer = await Self.currentContainer(),
                  let currentUser = currentContainer.currentUser else {
                become(sessionToken: sessionToken,
                       options: options,
                       callbackQueue: callbackQueue,
                       completion: completion)
                return
            }

            guard currentContainer.sessionToken == sessionToken else {
                let error = ParseError(code: .otherCause,
                                       message: """
                                   Currently logged in as a ParseUser who has a different
                                   session token than the Objective-C Parse SDK session token. Please log out before
                                   calling this method.
            """)
                callbackQueue.async {
                    completion(.failure(error))
                }
                return
            }
            callbackQueue.async {
                completion(.success(currentUser))
            }
        }
    }
#endif

    internal func meCommand(sessionToken: String) throws -> API.Command<Self, Self> {

        return API.Command(method: .GET,
                           path: endpoint) { (data) async throws -> Self in
            let user = try ParseCoding.jsonDecoder().decode(Self.self, from: data)

            if let current = try? await Self.current() {
                let isAnonymous = await self.anonymous.isLinked()
                if !current.hasSameObjectId(as: user) && isAnonymous {
                    await Self.deleteCurrentContainerFromKeychain()
                }
            }

            await Self.setCurrentContainer(.init(
                currentUser: user,
                sessionToken: sessionToken
            ))
            return user
        }
    }
}

// MARK: Logging Out
extension ParseUser {

    /**
     Logs out the currently logged in user *asynchronously*.

     This will also remove the session from the Keychain, log out of linked services
     and all future calls to `current` will return `nil`. This is preferable to using `logout`,
     unless your code is already running from a background thread.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: A block that will be called when logging out completes or fails.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    public static func logout(options: API.Options = [], callbackQueue: DispatchQueue = .main,
                              completion: @escaping (Result<Void, ParseError>) -> Void) {
        Task {
            var options = options
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            await logoutCommand().execute(options: options,
                                               callbackQueue: callbackQueue) { result in
                Task {
                    // Always let user logout locally, no matter the error.
                    await deleteCurrentKeychain()

                    switch result {

                    case .success(let error):
                        if let error = error {
                            completion(.failure(error))
                        } else {
                            completion(.success(()))
                        }
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    internal static func logoutCommand() -> API.Command<NoBody, ParseError?> {
        return API.Command(method: .POST, path: .logout) { (data) -> ParseError? in
            do {
                let parseError = try ParseCoding.jsonDecoder().decode(ParseError.self, from: data)
                return parseError
            } catch {
                return nil
            }
       }
    }
}

// MARK: Password Reset
extension ParseUser {

    /**
     Requests *asynchronously* a password reset email to be sent to the specified email address
     associated with the user account. This email allows the user to securely reset their password on the web.
        - parameter email: The email address associated with the user that forgot their password.
        - parameter options: A set of header options sent to the server. Defaults to an empty set.
        - parameter callbackQueue: The queue to return to after completion. Default value of .main.
        - parameter completion: A block that will be called when the password reset completes or fails.
        - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
        desires a different policy, it should be inserted in `options`.
    */
    public static func passwordReset(email: String, options: API.Options = [],
                                     callbackQueue: DispatchQueue = .main,
                                     completion: @escaping (Result<Void, ParseError>) -> Void) {
        Task {
            var options = options
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            await passwordResetCommand(email: email).execute(options: options,
                                                                  callbackQueue: callbackQueue) { result in
                switch result {

                case .success(let error):
                    if let error = error {
                        completion(.failure(error))
                    } else {
                        completion(.success(()))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    internal static func passwordResetCommand(email: String) -> API.Command<EmailBody, ParseError?> {
        let emailBody = EmailBody(email: email)
        return API.Command(method: .POST,
                           path: .passwordReset, body: emailBody) { (data) -> ParseError? in
            try? ParseCoding.jsonDecoder().decode(ParseError.self, from: data)
        }
    }
}

// MARK: Verify Password
extension ParseUser {

    /**
     Verifies *asynchronously* whether the specified password associated with the user account is valid.
        - parameter password: The password to be verified.
        - parameter usingPost: Set to **true** to use **POST** for sending. Will use **GET**
        otherwise. Defaults to **false**.
        - parameter options: A set of header options sent to the server. Defaults to an empty set.
        - parameter callbackQueue: The queue to return to after completion. Default value of .main.
        - parameter completion: A block that will be called when the verification request completes or fails.
        - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
        desires a different policy, it should be inserted in `options`.
        - warning: `usingPost == true` requires the
        [issue](https://github.com/parse-community/parse-server/issues/7784) to be addressed on
        the Parse Server, othewise you should set `usingPost = false`.
    */
    public static func verifyPassword(password: String,
                                      usingPost: Bool = false,
                                      options: API.Options = [],
                                      callbackQueue: DispatchQueue = .main,
                                      completion: @escaping (Result<Self, ParseError>) -> Void) {
        Task {
            var options = options
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            let currentUserName = try? await BaseParseUser.current().username
            let username = currentUserName ?? ""
            let method: API.Method = usingPost ? .POST : .GET
            await verifyPasswordCommand(username: username,
                                        password: password,
                                        method: method)
            .execute(options: options,
                          callbackQueue: callbackQueue,
                          completion: completion)
        }
    }

    internal static func verifyPasswordCommand(username: String,
                                               password: String,
                                               method: API.Method) -> API.Command<SignupLoginBody, Self> {
        let loginBody: SignupLoginBody?
        let params: [String: String]?

        switch method {
        case .GET:
            loginBody = nil
            params = ["username": username, "password": password ]
        default:
            loginBody = SignupLoginBody(username: username, password: password)
            params = nil
        }

        return API.Command(method: method,
                           path: .verifyPassword,
                           params: params,
                           body: loginBody) { (data) -> Self in
            var sessionToken = await Self.currentContainer()?.sessionToken
            if let decodedSessionToken = try? ParseCoding.jsonDecoder()
                .decode(LoginSignupResponse.self, from: data).sessionToken {
                sessionToken = decodedSessionToken
            }
            let user = try ParseCoding.jsonDecoder().decode(Self.self, from: data)
            await Self.setCurrentContainer(.init(currentUser: user,
                                           sessionToken: sessionToken))
            return user
        }
    }
}

// MARK: Verification Email Request
extension ParseUser {

    /**
     Requests *asynchronously* a verification email be sent to the specified email address
     associated with the user account.
        - parameter email: The email address associated with the user.
        - parameter options: A set of header options sent to the server. Defaults to an empty set.
        - parameter callbackQueue: The queue to return to after completion. Default value of .main.
        - parameter completion: A block that will be called when the verification request completes or fails.
        - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
        desires a different policy, it should be inserted in `options`.
    */
    public static func verificationEmail(email: String,
                                         options: API.Options = [],
                                         callbackQueue: DispatchQueue = .main,
                                         completion: @escaping (Result<Void, ParseError>) -> Void) {
        Task {
            var options = options
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            await verificationEmailCommand(email: email)
                .execute(options: options, callbackQueue: callbackQueue) { result in
                    switch result {

                    case .success(let error):
                        if let error = error {
                            completion(.failure(error))
                        } else {
                            completion(.success(()))
                        }
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
        }
    }

    internal static func verificationEmailCommand(email: String) -> API.Command<EmailBody, ParseError?> {
        let emailBody = EmailBody(email: email)
        return API.Command(method: .POST,
                           path: .verificationEmail,
                           body: emailBody) { (data) -> ParseError? in
            try? ParseCoding.jsonDecoder().decode(ParseError.self, from: data)
        }
    }
}

// MARK: Signing Up
extension ParseUser {

    /**
     Signs up the user *asynchronously*.

     This will also enforce that the username is not already taken.

     - warning: Make sure that password and username are set before calling this method.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    public func signup(options: API.Options = [], callbackQueue: DispatchQueue = .main,
                       completion: @escaping (Result<Self, ParseError>) -> Void) {
        Task {
            var options = options
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            do {
                _ = try await Self.current()
                do {
                    try await self.linkCommand()
                        .execute(options: options,
                                      callbackQueue: callbackQueue,
                                      completion: completion)
                } catch {
                    let parseError = error as? ParseError ?? ParseError(swift: error)
                    callbackQueue.async {
                        completion(.failure(parseError))
                    }
                }
            } catch {
                do {
                    try await signupCommand()
                        .execute(options: options,
                                      callbackQueue: callbackQueue,
                                      completion: completion)
                } catch {
                    let parseError = error as? ParseError ?? ParseError(swift: error)
                    callbackQueue.async {
                        completion(.failure(parseError))
                    }
                }
            }
        }
    }

    /**
     Signs up the user *asynchronously*.

     This will also enforce that the username is not already taken.

     - warning: Make sure that password and username are set before calling this method.
     - parameter username: The username of the user.
     - parameter password: The password of the user.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    public static func signup(username: String,
                              password: String,
                              options: API.Options = [],
                              callbackQueue: DispatchQueue = .main,
                              completion: @escaping (Result<Self, ParseError>) -> Void) {

        Task {
            var options = options
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            let body = SignupLoginBody(username: username, password: password)
            do {
                let current = try await Self.current()
                do {
                    try await current.linkCommand(body: body)
                        .execute(options: options,
                                 callbackQueue: callbackQueue) { result in
                            completion(result)
                        }
                } catch {
                    let parseError = error as? ParseError ?? ParseError(swift: error)
                    callbackQueue.async {
                        completion(.failure(parseError))
                    }
                }
            } catch {
                do {
                    try await signupCommand(body: body)
                        .execute(options: options,
                                      callbackQueue: callbackQueue,
                                      completion: completion)
                } catch {
                    let parseError = error as? ParseError ?? ParseError(swift: error)
                    callbackQueue.async {
                        completion(.failure(parseError))
                    }
                }
            }
        }
    }

    internal static func signupCommand(body: SignupLoginBody) throws -> API.Command<SignupLoginBody, Self> {
        API.Command(method: .POST,
                    path: .users,
                    body: body) { (data) -> Self in

            let sessionToken = try ParseCoding.jsonDecoder()
                .decode(LoginSignupResponse.self, from: data).sessionToken
            var user = try ParseCoding.jsonDecoder().decode(Self.self, from: data)

            if user.username == nil {
                if let username = body.username {
                    user.username = username
                }
            }
            if user.authData == nil {
                if let authData = body.authData {
                    user.authData = authData
                }
            }
            await Self.setCurrentContainer(.init(currentUser: user,
                                                 sessionToken: sessionToken))
            return user
        }
    }

    internal func signupCommand() throws -> API.Command<Self, Self> {

        API.Command(method: .POST,
                    path: endpoint,
                    body: self) { (data) -> Self in

            let response = try ParseCoding.jsonDecoder()
                .decode(LoginSignupResponse.self, from: data)
            let user = response.applySignup(to: self)
            await Self.setCurrentContainer(.init(
                currentUser: user,
                sessionToken: response.sessionToken
            ))
            return user
        }
    }
}

// MARK: Fetchable
extension ParseUser {
    internal static func updateKeychainIfNeeded(_ results: [Self], deleting: Bool = false) async throws {
        let currentUser = try await Self.current()
        var foundCurrentUserObjects = results.filter { $0.hasSameObjectId(as: currentUser) }
        foundCurrentUserObjects = try foundCurrentUserObjects.sorted(by: {
            guard let firstUpdatedAt = $0.updatedAt,
                  let secondUpdatedAt = $1.updatedAt else {
                throw ParseError(code: .otherCause,
                                 message: "Objects from the server should always have an \"updatedAt\"")
            }
            return firstUpdatedAt.compare(secondUpdatedAt) == .orderedDescending
        })
        if let foundCurrentUser = foundCurrentUserObjects.first {
            if !deleting {
                try await Self.setCurrent(foundCurrentUser)
            } else {
                await Self.deleteCurrentContainerFromKeychain()
            }
        }
    }

    /**
     Fetches the `ParseUser` *asynchronously* and executes the given callback block.
     - parameter includeKeys: The name(s) of the key(s) to include that are
     `ParseObject`s. Use `["*"]` to include all keys one level deep. This is similar to `include` and
     `includeAll` for `Query`.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default
     value of .main.
     - parameter completion: The block to execute when completed.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
     - important: If an object fetched has the same objectId as current, it will automatically update the current.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    public func fetch(
        includeKeys: [String]? = nil,
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<Self, ParseError>) -> Void
    ) {
        Task {
            var options = options
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            do {
                try await fetchCommand(include: includeKeys)
                    .execute(options: options,
                             callbackQueue: callbackQueue) { result in
                        if case .success(let foundResult) = result {
                            Task {
                                try? await Self.updateKeychainIfNeeded([foundResult])
                                completion(.success(foundResult))
                            }
                        } else {
                            completion(result)
                        }
                    }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

    func fetchCommand(include: [String]?) throws -> API.Command<Self, Self> {
        guard objectId != nil else {
            throw ParseError(code: .missingObjectId,
                             message: "objectId must not be nil")
        }

        var params: [String: String]?
        if let includeParams = include {
            params = ["include": "\(Set(includeParams))"]
        }

        return API.Command(method: .GET,
                           path: endpoint,
                           params: params) { (data) -> Self in
            try ParseCoding.jsonDecoder().decode(Self.self, from: data)
        }
    }
}

// MARK: Savable
extension ParseUser {

    /**
     Saves the `ParseUser` *asynchronously* and executes the given callback block.

     - parameter ignoringCustomObjectIdConfig: Ignore checking for `objectId`
     when `ParseConfiguration.isRequiringCustomObjectIds = true` to allow for mixed
     `objectId` environments. Defaults to false.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
     - important: If an object saved has the same objectId as current, it will automatically update the current.
     - warning: If you are using `ParseConfiguration.isRequiringCustomObjectIds = true`
     and plan to generate all of your `objectId`'s on the client-side then you should leave
     `ignoringCustomObjectIdConfig = false`. Setting
     `ParseConfiguration.isRequiringCustomObjectIds = true` and
     `ignoringCustomObjectIdConfig = true` means the client will generate `objectId`'s
     and the server will generate an `objectId` only when the client does not provide one. This can
     increase the probability of colliiding `objectId`'s as the client and server `objectId`'s may be generated using
     different algorithms. This can also lead to overwriting of `ParseObject`'s by accident as the
     client-side checks are disabled. Developers are responsible for handling such cases.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    public func save(
        ignoringCustomObjectIdConfig: Bool = false,
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<Self, ParseError>) -> Void
    ) {
        let method = Method.save
        Task {
            do {
                let object = try await command(method: method,
                                               ignoringCustomObjectIdConfig: ignoringCustomObjectIdConfig,
                                               options: options,
                                               callbackQueue: callbackQueue)
                callbackQueue.async {
                    completion(.success(object))
                }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

    /**
     Creates the `ParseUser` *asynchronously* and executes the given callback block.

     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
    */
    public func create(
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<Self, ParseError>) -> Void
    ) {
        let method = Method.create
        Task {
            do {
                let object = try await command(method: method,
                                               options: options,
                                               callbackQueue: callbackQueue)
                callbackQueue.async {
                    completion(.success(object))
                }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

    /**
     Replaces the `ParseUser` *asynchronously* and executes the given callback block.

     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
     - important: If an object replaced has the same objectId as current, it will automatically replace the current.
    */
    public func replace(
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<Self, ParseError>) -> Void
    ) {
        let method = Method.replace
        Task {
            do {
                let object = try await command(method: method,
                                               options: options,
                                               callbackQueue: callbackQueue)
                callbackQueue.async {
                    completion(.success(object))
                }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

    /**
     Updates the `ParseUser` *asynchronously* and executes the given callback block.

     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<Self, ParseError>)`.
     - important: If an object updated has the same objectId as current, it will automatically update the current.
    */
    internal func update(
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<Self, ParseError>) -> Void
    ) {
        let method = Method.update
        Task {
            do {
                let object = try await command(method: method,
                                               options: options,
                                               callbackQueue: callbackQueue)
                callbackQueue.async {
                    completion(.success(object))
                }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

    func saveCommand(ignoringCustomObjectIdConfig: Bool = false) async throws -> API.Command<Self, Self> {
        if Parse.configuration.isRequiringCustomObjectIds && objectId == nil && !ignoringCustomObjectIdConfig {
            throw ParseError(code: .missingObjectId, message: "objectId must not be nil")
        }
        if isSaved {
            return try await replaceCommand() // MARK: Should be switched to "updateCommand" when server supports PATCH.
        }
        return await createCommand()
    }

    // MARK: Saving ParseObjects - private
    func createCommand() async -> API.Command<Self, Self> {
        var object = self
        if object.ACL == nil,
            let acl = try? await ParseACL.defaultACL() {
            object.ACL = acl
        }
        let mapper = { (data) -> Self in
            try ParseCoding.jsonDecoder().decode(CreateResponse.self, from: data).apply(to: object)
        }
        return API.Command<Self, Self>(method: .POST,
                                       path: endpoint(.POST),
                                       body: object,
                                       mapper: mapper)
    }

    func replaceCommand() async throws -> API.Command<Self, Self> {
        guard self.objectId != nil else {
            throw ParseError(code: .missingObjectId,
                             message: "objectId must not be nil")
        }
        var mutableSelf = self
        if let currentUser = try? await Self.current(),
           currentUser.hasSameObjectId(as: mutableSelf) {
            if currentUser.email == mutableSelf.email {
                mutableSelf.email = nil
            }
        }
        let mapper = { (data: Data) -> Self in
            var updatedObject = self
            updatedObject.originalData = nil
            updatedObject = try ParseCoding.jsonDecoder().decode(ReplaceResponse.self,
                                                                 from: data).apply(to: updatedObject)
            // MARK: The lines below should be removed when server supports PATCH.
            guard let originalData = self.originalData,
                  let original = try? ParseCoding.jsonDecoder().decode(Self.self,
                                                                       from: originalData),
                  original.hasSameObjectId(as: updatedObject) else {
                      return updatedObject
                  }
            return try updatedObject.merge(with: original)
        }
        return API.Command<Self, Self>(method: .PUT,
                                 path: endpoint,
                                 body: mutableSelf,
                                 mapper: mapper)
    }

    func updateCommand() async throws -> API.Command<Self, Self> {
        guard self.objectId != nil else {
            throw ParseError(code: .missingObjectId,
                             message: "objectId must not be nil")
        }
        var mutableSelf = self
        if let currentUser = try? await Self.current(),
           currentUser.hasSameObjectId(as: mutableSelf) {
            if currentUser.email == mutableSelf.email {
                mutableSelf.email = nil
            }
        }
        let mapper = { (data: Data) -> Self in
            var updatedObject = self
            updatedObject.originalData = nil
            updatedObject = try ParseCoding.jsonDecoder().decode(UpdateResponse.self,
                                                                 from: data).apply(to: updatedObject)
            guard let originalData = self.originalData,
                  let original = try? ParseCoding.jsonDecoder().decode(Self.self,
                                                                       from: originalData),
                  original.hasSameObjectId(as: updatedObject) else {
                      return updatedObject
                  }
            return try updatedObject.merge(with: original)
        }
        return API.Command<Self, Self>(method: .PATCH,
                                 path: endpoint,
                                 body: mutableSelf,
                                 mapper: mapper)
    }
}

// MARK: Deletable
extension ParseUser {

    /**
     Deletes the `ParseUser` *asynchronously* and executes the given callback block.

     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default
     value of .main.
     - parameter completion: The block to execute when completed.
     It should have the following argument signature: `(Result<Void, ParseError>)`.
     - important: If an object deleted has the same objectId as current, it will automatically update the current.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    public func delete(
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<Void, ParseError>) -> Void
    ) {
        Task {
            var options = options
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            do {
                try await deleteCommand().execute(options: options,
                                                       callbackQueue: callbackQueue) { result in
                    switch result {

                    case .success:
                        Task {
                            try? await Self.updateKeychainIfNeeded([self], deleting: true)
                            completion(.success(()))
                        }
                    case .failure(let error):
                        callbackQueue.async {
                            completion(.failure(error))
                        }
                    }
                }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

    func deleteCommand() throws -> API.NonParseBodyCommand<NoBody, NoBody> {
        guard isSaved else {
            throw ParseError(code: .otherCause, message: "Cannot Delete an object without id")
        }

        return API.NonParseBodyCommand<NoBody, NoBody>(
            method: .DELETE,
            path: endpoint
        ) { (data) -> NoBody in
            let error = try? ParseCoding.jsonDecoder().decode(ParseError.self, from: data)
            if let error = error {
                throw error
            } else {
                return NoBody()
            }
        }
    }
}

// MARK: Batch Support
public extension Sequence where Element: ParseUser {

    /**
     Saves a collection of users all at once *asynchronously* and executes the completion block when done.
     - parameter batchLimit: The maximum number of objects to send in each batch. If the amount of items to be batched
     is greater than the `batchLimit`, the objects will be sent to the server in waves up to the `batchLimit`.
     Defaults to 50.
     - parameter transaction: Treat as an all-or-nothing operation. If some operation failure occurs that
     prevents the transaction from completing, then none of the objects are committed to the Parse Server database.
     - parameter ignoringCustomObjectIdConfig: Ignore checking for `objectId`
     when `ParseConfiguration.isRequiringCustomObjectIds = true` to allow for mixed
     `objectId` environments. Defaults to false.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<[(Result<Element, ParseError>)], ParseError>)`.
     - important: If an object saved has the same objectId as current, it will automatically update the current.
     - warning: If `transaction = true`, then `batchLimit` will be automatically be set to the amount of the
     objects in the transaction. The developer should ensure their respective Parse Servers can handle the limit or else
     the transactions can fail.
     - warning: If you are using `ParseConfiguration.isRequiringCustomObjectIds = true`
     and plan to generate all of your `objectId`'s on the client-side then you should leave
     `ignoringCustomObjectIdConfig = false`. Setting
     `ParseConfiguration.isRequiringCustomObjectIds = true` and
     `ignoringCustomObjectIdConfig = true` means the client will generate `objectId`'s
     and the server will generate an `objectId` only when the client does not provide one. This can
     increase the probability of colliiding `objectId`'s as the client and server `objectId`'s may be generated using
     different algorithms. This can also lead to overwriting of `ParseObject`'s by accident as the
     client-side checks are disabled. Developers are responsible for handling such cases.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    func saveAll(
        batchLimit limit: Int? = nil,
        transaction: Bool = configuration.isUsingTransactions,
        ignoringCustomObjectIdConfig: Bool = false,
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<[(Result<Element, ParseError>)], ParseError>) -> Void
    ) {
        let method = Method.save
        Task {
            do {
                let objects = try await batchCommand(method: method,
                                                     batchLimit: limit,
                                                     transaction: transaction,
                                                     ignoringCustomObjectIdConfig: ignoringCustomObjectIdConfig,
                                                     options: options,
                                                     callbackQueue: callbackQueue)
                callbackQueue.async {
                    completion(.success(objects))
                }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

    /**
     Creates a collection of users all at once *asynchronously* and executes the completion block when done.
     - parameter batchLimit: The maximum number of objects to send in each batch. If the amount of items to be batched
     is greater than the `batchLimit`, the objects will be sent to the server in waves up to the `batchLimit`.
     Defaults to 50.
     - parameter transaction: Treat as an all-or-nothing operation. If some operation failure occurs that
     prevents the transaction from completing, then none of the objects are committed to the Parse Server database.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<[(Result<Element, ParseError>)], ParseError>)`.
     - warning: If `transaction = true`, then `batchLimit` will be automatically be set to the amount of the
     objects in the transaction. The developer should ensure their respective Parse Servers can handle the limit or else
     the transactions can fail.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    func createAll(
        batchLimit limit: Int? = nil,
        transaction: Bool = configuration.isUsingTransactions,
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<[(Result<Element, ParseError>)], ParseError>) -> Void
    ) {
        let method = Method.create
        Task {
            do {
                let objects = try await batchCommand(method: method,
                                                     batchLimit: limit,
                                                     transaction: transaction,
                                                     options: options,
                                                     callbackQueue: callbackQueue)
                callbackQueue.async {
                    completion(.success(objects))
                }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

    /**
     Replaces a collection of users all at once *asynchronously* and executes the completion block when done.
     - parameter batchLimit: The maximum number of objects to send in each batch. If the amount of items to be batched
     is greater than the `batchLimit`, the objects will be sent to the server in waves up to the `batchLimit`.
     Defaults to 50.
     - parameter transaction: Treat as an all-or-nothing operation. If some operation failure occurs that
     prevents the transaction from completing, then none of the objects are committed to the Parse Server database.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<[(Result<Element, ParseError>)], ParseError>)`.
     - important: If an object replaced has the same objectId as current, it will automatically replace the current.
     - warning: If `transaction = true`, then `batchLimit` will be automatically be set to the amount of the
     objects in the transaction. The developer should ensure their respective Parse Servers can handle the limit or else
     the transactions can fail.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    func replaceAll(
        batchLimit limit: Int? = nil,
        transaction: Bool = configuration.isUsingTransactions,
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<[(Result<Element, ParseError>)], ParseError>) -> Void
    ) {
        let method = Method.replace
        Task {
            do {
                let objects = try await batchCommand(method: method,
                                                     batchLimit: limit,
                                                     transaction: transaction,
                                                     options: options,
                                                     callbackQueue: callbackQueue)
                callbackQueue.async {
                    completion(.success(objects))
                }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

    /**
     Updates a collection of users all at once *asynchronously* and executes the completion block when done.
     - parameter batchLimit: The maximum number of objects to send in each batch. If the amount of items to be batched
     is greater than the `batchLimit`, the objects will be sent to the server in waves up to the `batchLimit`.
     Defaults to 50.
     - parameter transaction: Treat as an all-or-nothing operation. If some operation failure occurs that
     prevents the transaction from completing, then none of the objects are committed to the Parse Server database.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<[(Result<Element, ParseError>)], ParseError>)`.
     - important: If an object updated has the same objectId as current, it will automatically update the current.
     - warning: If `transaction = true`, then `batchLimit` will be automatically be set to the amount of the
     objects in the transaction. The developer should ensure their respective Parse Servers can handle the limit or else
     the transactions can fail.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    internal func updateAll(
        batchLimit limit: Int? = nil,
        transaction: Bool = configuration.isUsingTransactions,
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<[(Result<Element, ParseError>)], ParseError>) -> Void
    ) {
        let method = Method.update
        Task {
            do {
                let objects = try await batchCommand(method: method,
                                                     batchLimit: limit,
                                                     transaction: transaction,
                                                     options: options,
                                                     callbackQueue: callbackQueue)
                callbackQueue.async {
                    completion(.success(objects))
                }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }

    /**
     Fetches a collection of users all at once *asynchronously* and executes the completion block when done.
     - parameter includeKeys: The name(s) of the key(s) to include that are
     `ParseObject`s. Use `["*"]` to include all keys one level deep. This is similar to `include` and
     `includeAll` for `Query`.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<[(Result<Element, ParseError>)], ParseError>)`.
     - important: If an object fetched has the same objectId as current, it will automatically update the current.
     - warning: The order in which users are returned are not guarenteed. You should not expect results in
     any particular order.
    */
    func fetchAll(
        includeKeys: [String]? = nil,
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<[(Result<Element, ParseError>)], ParseError>) -> Void
    ) {
        if (allSatisfy { $0.className == Self.Element.className}) {
            let uniqueObjectIds = Set(compactMap { $0.objectId })
            var query = Self.Element.query(containedIn(key: "objectId", array: [uniqueObjectIds]))
            if let include = includeKeys {
                query = query.include(include)
            }
            query.find(options: options, callbackQueue: callbackQueue) { result in
                switch result {

                case .success(let fetchedObjects):
                    var fetchedObjectsToReturnMutable = [(Result<Self.Element, ParseError>)]()

                    uniqueObjectIds.forEach {
                        let uniqueObjectId = $0
                        if let fetchedObject = fetchedObjects.first(where: {$0.objectId == uniqueObjectId}) {
                            fetchedObjectsToReturnMutable.append(.success(fetchedObject))
                        } else {
                            let error = ParseError(code: .objectNotFound,
                                                   // swiftlint:disable:next line_length
                                                   message: "objectId \"\(uniqueObjectId)\" was not found in className \"\(Self.Element.className)\"")
                            fetchedObjectsToReturnMutable.append(.failure(error))
                        }
                    }
                    let fetchedObjectsToReturn = fetchedObjectsToReturnMutable
                    Task {
                        try? await Self.Element.updateKeychainIfNeeded(fetchedObjects)
                        callbackQueue.async {
                            completion(.success(fetchedObjectsToReturn))
                        }
                    }
                case .failure(let error):
                    callbackQueue.async {
                        completion(.failure(error))
                    }
                }
            }
        } else {
            callbackQueue.async {
                completion(.failure(ParseError(code: .otherCause,
                                               message: "all items to fetch must be of the same class")))
            }
        }
    }

    /**
     Deletes a collection of users all at once *asynchronously* and executes the completion block when done.
     - parameter batchLimit: The maximum number of objects to send in each batch. If the amount of items to be batched
     is greater than the `batchLimit`, the objects will be sent to the server in waves up to the `batchLimit`.
     Defaults to 50.
     - parameter transaction: Treat as an all-or-nothing operation. If some operation failure occurs that
     prevents the transaction from completing, then none of the objects are committed to the Parse Server database.
     - parameter options: A set of header options sent to the server. Defaults to an empty set.
     - parameter callbackQueue: The queue to return to after completion. Default value of .main.
     - parameter completion: The block to execute.
     It should have the following argument signature: `(Result<[ParseError?], ParseError>)`.
     Each element in the array is `nil` if the delete successful or a `ParseError` if it failed.
     1. A `ParseError.Code.aggregateError`. This object's "errors" property is an
     array of other Parse.Error objects. Each error object in this array
     has an "object" property that references the object that could not be
     deleted (for instance, because that object could not be found).
     2. A non-aggregate Parse.Error. This indicates a serious error that
     caused the delete operation to be aborted partway through (for
     instance, a connection failure in the middle of the delete).
     - important: If an object deleted has the same objectId as current, it will automatically update the current.
     - warning: If `transaction = true`, then `batchLimit` will be automatically be set to the amount of the
     objects in the transaction. The developer should ensure their respective Parse Servers can handle the limit or else
     the transactions can fail.
     - note: The default cache policy for this method is `.reloadIgnoringLocalCacheData`. If a developer
     desires a different policy, it should be inserted in `options`.
    */
    func deleteAll(
        batchLimit limit: Int? = nil,
        transaction: Bool = configuration.isUsingTransactions,
        options: API.Options = [],
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result<[(Result<Void, ParseError>)], ParseError>) -> Void
    ) {
        Task {
            var options = options
            options.insert(.cachePolicy(.reloadIgnoringLocalCacheData))
            do {
                var returnBatch = [(Result<Void, ParseError>)]()
                let commands = try map({ try $0.deleteCommand() })
                let batchLimit = limit != nil ? limit! : ParseConstants.batchLimit
                try canSendTransactions(transaction, objectCount: commands.count, batchLimit: batchLimit)
                let batches = BatchUtils.splitArray(commands, valuesPerSegment: batchLimit)
                var completed = 0
                for batch in batches {
                    await API.Command<Self.Element, ParseError?>
                        .batch(commands: batch, transaction: transaction)
                        .execute(options: options,
                                      callbackQueue: callbackQueue) { results in
                            switch results {

                            case .success(let saved):
                                returnBatch.append(contentsOf: saved)
                                if completed == (batches.count - 1) {
                                    let returnBatchImmutable = returnBatch
                                    Task {
                                        try? await Self.Element.updateKeychainIfNeeded(self.compactMap {$0},
                                                                                       deleting: true)
                                        callbackQueue.async {
                                            completion(.success(returnBatchImmutable))
                                        }
                                    }
                                }
                                completed += 1
                            case .failure(let error):
                                completion(.failure(error))
                                return
                            }
                        }
                }
            } catch {
                let parseError = error as? ParseError ?? ParseError(swift: error)
                callbackQueue.async {
                    completion(.failure(parseError))
                }
            }
        }
    }
} // swiftlint:disable:this file_length
