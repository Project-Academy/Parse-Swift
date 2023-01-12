//
//  URLSession.swift
//  ParseSwift
//
//  Original file, URLSession+sync.swift, created by Florent Vilmart on 17-09-24.
//  Name change to URLSession.swift and support for sync/async by Corey Baker on 7/25/20.
//  Copyright © 2020 Parse Community. All rights reserved.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

internal extension URLSession {
    #if !os(Linux) && !os(Android) && !os(Windows)
    static var parse = URLSession.shared
    #else
    static var parse: URLSession = {
        if !Parse.configuration.isTestingSDK {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache.parse
            configuration.requestCachePolicy = Parse.configuration.requestCachePolicy
            configuration.httpAdditionalHeaders = Parse.configuration.httpAdditionalHeaders
            return URLSession(configuration: configuration,
                              delegate: Parse.sessionDelegate,
                              delegateQueue: nil)
        } else {
            let session = URLSession.shared
            session.configuration.urlCache = URLCache.parse
            session.configuration.requestCachePolicy = Parse.configuration.requestCachePolicy
            session.configuration.httpAdditionalHeaders = Parse.configuration.httpAdditionalHeaders
            return session
        }
    }()
    #endif

    static func updateParseURLSession() {
        #if !os(Linux) && !os(Android) && !os(Windows)
        if !Parse.configuration.isTestingSDK {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache.parse
            configuration.requestCachePolicy = Parse.configuration.requestCachePolicy
            configuration.httpAdditionalHeaders = Parse.configuration.httpAdditionalHeaders
            Self.parse = URLSession(configuration: configuration,
                                    delegate: Parse.sessionDelegate,
                                    delegateQueue: nil)
        } else {
            let session = URLSession.shared
            session.configuration.urlCache = URLCache.parse
            session.configuration.requestCachePolicy = Parse.configuration.requestCachePolicy
            session.configuration.httpAdditionalHeaders = Parse.configuration.httpAdditionalHeaders
            Self.parse = session
        }
        #endif
    }

    static func reconnectInterval(_ maxExponent: Int) -> Int {
        let min = NSDecimalNumber(decimal: Swift.min(30, pow(2, maxExponent) - 1))
        return Int.random(in: 0 ..< Int(truncating: min))
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func makeResult<U>(request: URLRequest,
                       responseData: Data?,
                       urlResponse: URLResponse?,
                       responseError: Error?,
                       mapper: @escaping (Data) throws -> U) -> Result<U, ParseError> {
        if let responseError = responseError {
            guard let parseError = responseError as? ParseError else {
                return .failure(ParseError(code: .otherCause,
                                           message: "Unable to connect with parse-server: \(responseError)"))
            }
            return .failure(parseError)
        }
        guard let response = urlResponse else {
            guard let parseError = responseError as? ParseError else {
                return .failure(ParseError(code: .otherCause,
                                           message: "No response from server"))
            }
            return .failure(parseError)
        }
        if var responseData = responseData {
            if let error = try? ParseCoding.jsonDecoder().decode(ParseError.self, from: responseData) {
                return .failure(error)
            }
            if URLSession.parse.configuration.urlCache?.cachedResponse(for: request) == nil {
                URLSession.parse.configuration.urlCache?
                    .storeCachedResponse(.init(response: response,
                                               data: responseData),
                                         for: request)
            }
            if let httpResponse = response as? HTTPURLResponse {
                if let pushStatusId = httpResponse.value(forHTTPHeaderField: "X-Parse-Push-Status-Id") {
                    let pushStatus = PushResponse(data: responseData, statusId: pushStatusId)
                    do {
                        responseData = try ParseCoding.jsonEncoder().encode(pushStatus)
                    } catch {
                        URLSession.parse.configuration.urlCache?.removeCachedResponse(for: request)
                        return .failure(ParseError(code: .otherCause, message: error.localizedDescription))
                    }
                }
            }
            do {
                return try .success(mapper(responseData))
            } catch {
                URLSession.parse.configuration.urlCache?.removeCachedResponse(for: request)
                guard let parseError = error as? ParseError else {
                    guard JSONSerialization.isValidJSONObject(responseData),
                          let json = try? JSONSerialization
                            .data(withJSONObject: responseData,
                              options: .prettyPrinted) else {
                        let nsError = error as NSError
                        if nsError.code == 4865,
                          let description = nsError.userInfo["NSDebugDescription"] {
                            return .failure(ParseError(code: .otherCause, message: "Invalid struct: \(description)"))
                        }
                        return .failure(ParseError(code: .otherCause,
                                                   // swiftlint:disable:next line_length
                                                   message: "Error decoding parse-server response: \(response) with error: \(String(describing: error)) Format: \(String(describing: String(data: responseData, encoding: .utf8)))"))
                    }
                    return .failure(ParseError(code: .otherCause,
                                               // swiftlint:disable:next line_length
                                               message: "Error decoding parse-server response: \(response) with error: \(String(describing: error)) Format: \(String(describing: String(data: json, encoding: .utf8)))"))
                }
                return .failure(parseError)
            }
        }

        return .failure(ParseError(code: .otherCause,
                                   message: "Unable to connect with parse-server: \(String(describing: urlResponse))."))
    }

    func makeResult<U>(request: URLRequest,
                       location: URL?,
                       urlResponse: URLResponse?,
                       responseError: Error?,
                       mapper: @escaping (Data) throws -> U) -> Result<U, ParseError> {
        guard let response = urlResponse else {
            guard let parseError = responseError as? ParseError else {
                return .failure(ParseError(code: .otherCause,
                                           message: "No response from server"))
            }
            return .failure(parseError)
        }
        if let responseError = responseError {
            guard let parseError = responseError as? ParseError else {
                return .failure(ParseError(code: .otherCause,
                                           message: "Unable to connect with parse-server: \(responseError)"))
            }
            return .failure(parseError)
        }

        if let location = location {
            do {
                let data = try ParseCoding.jsonEncoder().encode(location)
                return try .success(mapper(data))
            } catch {
                let defaultError = ParseError(code: .otherCause,
                                              // swiftlint:disable:next line_length
                                              message: "Error decoding parse-server response: \(response) with error: \(String(describing: error))")
                let parseError = error as? ParseError ?? defaultError
                return .failure(parseError)
            }
        }

        return .failure(ParseError(code: .otherCause,
                                   message: "Unable to connect with parse-server: \(response)."))
    }

    static func computeDelay(_ seconds: Int) -> TimeInterval? {
        Calendar.current.date(byAdding: .second,
                              value: seconds,
                              to: Date())?.timeIntervalSinceNow
    }

    static func computeDelay(_ delayString: String) -> TimeInterval? {
        guard let seconds = Int(delayString) else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "E, d MMM yyyy HH:mm:ss z"
            guard let delayUntil = dateFormatter.date(from: delayString) else {
                return nil
            }
            return delayUntil.timeIntervalSinceNow
        }
        return computeDelay(seconds)
    }

    // swiftlint:disable:next function_body_length
    func dataTask<U>(
        with request: URLRequest,
        callbackQueue: DispatchQueue,
        attempts: Int = 1,
        allowIntermediateResponses: Bool,
        mapper: @escaping (Data) throws -> U,
        completion: @escaping(Result<U, ParseError>) -> Void
    ) {

        dataTask(with: request) { (responseData, urlResponse, responseError) in
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                completion(self.makeResult(request: request,
                                           responseData: responseData,
                                           urlResponse: urlResponse,
                                           responseError: responseError,
                                           mapper: mapper))
                return
            }
            let statusCode = httpResponse.statusCode
            guard (200...299).contains(statusCode) else {

                let attempts = attempts + 1

                // Retry if max attempts have not been reached.
                guard attempts <= Parse.configuration.maxConnectionAttempts else {
                    // If max attempts have been reached update the client now.
                    completion(self.makeResult(request: request,
                                               responseData: responseData,
                                               urlResponse: urlResponse,
                                               responseError: responseError,
                                               mapper: mapper))
                    return
                }

                // If there is current response data, update the client now.
                if allowIntermediateResponses,
                    let responseData = responseData {
                    completion(self.makeResult(request: request,
                                               responseData: responseData,
                                               urlResponse: urlResponse,
                                               responseError: responseError,
                                               mapper: mapper))
                }

                let delayInterval: TimeInterval!

                // Check for constant delays in header information.
                switch statusCode {
                case 429:
                    if let delayString = httpResponse.value(forHTTPHeaderField: "x-rate-limit-reset"),
                       let constantDelay = Self.computeDelay(delayString) {
                        delayInterval = constantDelay
                    } else {
                        delayInterval = Self.computeDelay(Self.reconnectInterval(2))
                    }

                case 503:
                    if let delayString = httpResponse.value(forHTTPHeaderField: "retry-after"),
                       let constantDelay = Self.computeDelay(delayString) {
                        delayInterval = constantDelay
                    } else {
                        delayInterval = Self.computeDelay(Self.reconnectInterval(2))
                    }

                default:
                    delayInterval = Self.computeDelay(Self.reconnectInterval(2))
                }

                callbackQueue.asyncAfter(deadline: .now() + delayInterval) {
                    self.dataTask(with: request,
                                  callbackQueue: callbackQueue,
                                  attempts: attempts,
                                  allowIntermediateResponses: allowIntermediateResponses,
                                  mapper: mapper,
                                  completion: completion)
                }
                return
            }
            completion(self.makeResult(request: request,
                                       responseData: responseData,
                                       urlResponse: urlResponse,
                                       responseError: responseError,
                                       mapper: mapper))
        }.resume()
    }
}

internal extension URLSession {
    func uploadTask<U>( // swiftlint:disable:this function_body_length function_parameter_count
        notificationQueue: DispatchQueue,
        with request: URLRequest,
        from data: Data?,
        from file: URL?,
        progress: ((URLSessionTask, Int64, Int64, Int64) -> Void)?,
        mapper: @escaping (Data) throws -> U,
        completion: @escaping(Result<U, ParseError>) -> Void
    ) {
        var task: URLSessionTask?
        if let data = data {
            do {
                task = try ParseSwift
                    .configuration
                    .parseFileTransfer
                    .upload(with: request,
                            from: data) { (responseData, urlResponse, updatedRequest, responseError) in
                    completion(self.makeResult(request: updatedRequest ?? request,
                                               responseData: responseData,
                                               urlResponse: urlResponse,
                                               responseError: responseError,
                                               mapper: mapper))
                }
            } catch {
                let defaultError = ParseError(code: .otherCause,
                                              message: "Error uploading file: \(String(describing: error))")
                let parseError = error as? ParseError ?? defaultError
                completion(.failure(parseError))
            }
        } else if let file = file {
            do {
                task = try ParseSwift
                    .configuration
                    .parseFileTransfer
                    .upload(with: request,
                            fromFile: file) { (responseData, urlResponse, updatedRequest, responseError) in
                    completion(self.makeResult(request: updatedRequest ?? request,
                                               responseData: responseData,
                                               urlResponse: urlResponse,
                                               responseError: responseError,
                                               mapper: mapper))
                }
            } catch {
                let defaultError = ParseError(code: .otherCause,
                                              message: "Error uploading file: \(String(describing: error))")
                let parseError = error as? ParseError ?? defaultError
                completion(.failure(parseError))
            }
        } else {
            completion(.failure(ParseError(code: .otherCause, message: "data and file both cannot be nil")))
        }
        guard let task = task else {
            return
        }
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        Task {
            await Parse.sessionDelegate.delegates.updateUpload(task, callback: progress)
            await Parse.sessionDelegate.delegates.updateTask(task, queue: notificationQueue)
            task.resume()
        }
        #else
        Parse.sessionDelegate.uploadDelegates[task] = progress
        Parse.sessionDelegate.taskCallbackQueues[task] = notificationQueue
        task.resume()
        #endif
    }

    func downloadTask<U>(
        notificationQueue: DispatchQueue,
        with request: URLRequest,
        progress: ((URLSessionDownloadTask, Int64, Int64, Int64) -> Void)?,
        mapper: @escaping (Data) throws -> U,
        completion: @escaping(Result<U, ParseError>) -> Void
    ) {
        let task = downloadTask(with: request) { (location, urlResponse, responseError) in
            let result = self.makeResult(request: request,
                                         location: location,
                                         urlResponse: urlResponse,
                                         responseError: responseError, mapper: mapper)
            completion(result)
        }
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        Task {
            await Parse.sessionDelegate.delegates.updateDownload(task, callback: progress)
            await Parse.sessionDelegate.delegates.updateTask(task, queue: notificationQueue)
            task.resume()
        }
        #else
        Parse.sessionDelegate.downloadDelegates[task] = progress
        Parse.sessionDelegate.taskCallbackQueues[task] = notificationQueue
        task.resume()
        #endif
    }

    func downloadTask<U>(
        with request: URLRequest,
        mapper: @escaping (Data) throws -> U,
        completion: @escaping(Result<U, ParseError>) -> Void
    ) {
        downloadTask(with: request) { (location, urlResponse, responseError) in
            completion(self.makeResult(request: request,
                                       location: location,
                                       urlResponse: urlResponse,
                                       responseError: responseError,
                                       mapper: mapper))
        }.resume()
    }
}
