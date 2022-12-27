//
//  Created by Harjeet Singh on 05/09/20.
//

import Foundation
import UIKit
import MobileCoreServices

public protocol UploadProgressDelegate {
    func didReceivedProgress(progress:Float)
    func didFailToUpload(error: String)
}

public protocol DownloadProgressDelegate {
    func didReceivedDownloadProgress(progress:Float, filename:String)
    func didFailedDownload(filename:String)
}

public class RequestManager {
    
    // MARK: - Vars & Lets
    public var delegate : UploadProgressDelegate?
    public var downloadDelegate : DownloadProgressDelegate?
    
    private let sessionManager: SessionManager
    private let retrier: RequestManagerRetrier
    public static var networkEnviroment: NetworkEnvironment = .dev
    
    // MARK: - Public methods
    
    public func call<T>(type: EndPointType,
                        params: Parameters? = nil,
                        queryParameter: Parameters? = nil,
                        pathParameters: String? = nil,
                        cookies: [HTTPCookiePropertyKey : Any]? = nil,
                        handler: @escaping (Swift.Result<T, AlertMessage>, HTTPURLResponse?) -> Void) where T: Codable {
        var requestURL = type.url
        if let pathParam = pathParameters{
            requestURL = URL(string: requestURL.description + pathParam)!
        }
        if let queryParam = queryParameter{
            for key in queryParam.keys{
                if let url = requestURL.appendParameters(whereKey: key, value: queryParam[key]){
                    requestURL = url
                }
            }
        }
        if let `cookies` = cookies, let cookiesProps = HTTPCookie(properties: cookies) {
            self.sessionManager.session.configuration.httpCookieStorage?.setCookie(cookiesProps)
        }
        self.sessionManager.request(
            requestURL,
            method: type.httpMethod,
            parameters: params,
            encoding: type.encoding,
            headers: type.headers).validate().responseJSON { (responseJSON) in
                do {
                    guard let jsonData = responseJSON.data else {
                        throw AlertMessage(title: "Error", body: "No data")
                    }
                    let result = try JSONDecoder().decode(T.self, from: jsonData)
                    handler(.success(result), responseJSON.response)
                    self.resetNumberOfRetries()
                } catch let error{
                    print(error.localizedDescription)
                    handler(.failure(self.parseApiError(data: responseJSON.data)), responseJSON.response)
                }
        }
    }
    
    public func download(url: URL,
                         param: Parameters? = nil,
                         method: HTTPMethod,
                         encoding: ParameterEncoding = JSONEncoding.default,
                         headers: HTTPHeaders? = nil,
                         destination: DownloadRequest.DownloadFileDestination? = nil,
                         handler: @escaping(Swift.Result<String, AlertMessage>, HTTPURLResponse?) -> Void){
        
        self.sessionManager.download(url, method: method, parameters: param, encoding: encoding, headers: headers, to: destination)
            .downloadProgress { (progress) in
                self.downloadDelegate?.didReceivedDownloadProgress(progress: Float(progress.fractionCompleted), filename: url.lastPathComponent)
        }
            .responseData { (responseData) in
                if responseData.result.isSuccess, let filePath = responseData.destinationURL?.path {
                    handler(.success(filePath), responseData.response)
                }else{
                    handler(.failure(AlertMessage(title: "Error", body: responseData.error?.localizedDescription ?? "")), responseData.response)
                }
            }
    }
    
    public func upload<T>(type: EndPointType,
                          params: Parameters = [:],
                          queryParameter: Parameters? = nil,
                          pathParameters: String? = nil,
                          handler: @escaping (Swift.Result<T, AlertMessage>, HTTPURLResponse?) -> Void) where T: Codable {
        var requestURL = type.url
        if let pathParam = pathParameters{
            requestURL = URL(string: requestURL.description + pathParam)!
        }
        if let queryParam = queryParameter{
            for key in queryParam.keys{
                if let url = requestURL.appendParameters(whereKey: key, value: queryParam[key]){
                    requestURL = url
                }
            }
        }
        self.sessionManager.upload(
            multipartFormData: { (multipartFormData) in
                
                for (key, value) in params {
                    let key = key
                    if let value = value as? UIImage {
                        if let imageData = value.jpegData(compressionQuality: 0.7) {
                            multipartFormData.append(imageData, withName: key, fileName: "swift_file.jpg", mimeType: "image/*")
                        }
                        
                    } else if let value = value as? URL {
                        do {
                            let mimeType = value.getMimeType()
                            let valueData = try Data (contentsOf: value, options: .mappedIfSafe)
                            multipartFormData.append(
                                valueData,
                                withName: key,
                                fileName: value.lastPathComponent,
                                mimeType: mimeType)
                        } catch {
                            print(error)
                            return
                        }
                    } else if let value = value as? NSArray {
                        for childValue in value {
                            if let childValue = childValue as? UIImage {
                                if let imageData = childValue.jpegData(compressionQuality: 0.7) {
                                    multipartFormData.append(imageData, withName: key, fileName: "swift_file.jpg", mimeType: "image/*")
                                }
                            } else if let childValue = childValue as? URL {
                                do {
                                    let mimeType = childValue.getMimeType()
                                    let valueData = try Data (contentsOf: childValue, options: .mappedIfSafe)
                                    multipartFormData.append(
                                        valueData,
                                        withName: key,
                                        fileName: childValue.lastPathComponent,
                                        mimeType: mimeType)
                                } catch {
                                    print(error)
                                    return
                                }
                            }
                        }
                    } else if let otherValue = "\(value)".data(using: .utf8) {
                        multipartFormData.append(otherValue, withName: key)
                    }
                }
        },
            to: requestURL,
            method: type.httpMethod,
            headers: type.headers) { encodingResult in
                switch encodingResult {
                case .success(let upload, _, _):
                    
                    upload.uploadProgress(closure: { (progress) in
                        self.delegate?.didReceivedProgress(progress: Float(progress.fractionCompleted))
                    })
                    
                    upload.responseJSON { responseJSON in
                        do {
                            guard let jsonData = responseJSON.data else {
                                throw AlertMessage(title: "Error", body: "No data")
                            }
                            let result = try JSONDecoder().decode(T.self, from: jsonData)
                            handler(.success(result), responseJSON.response)
                            self.resetNumberOfRetries()
                        } catch {
                            if let error = error as? AlertMessage {
                                return handler(.failure(error), responseJSON.response)
                            }
                            
                            handler(.failure(self.parseApiError(data: responseJSON.data)), responseJSON.response)
                        }
                    }
                case .failure(let error):
                    handler(.failure(AlertMessage(title: "Error", body: error.localizedDescription)), nil)
                    self.delegate?.didFailToUpload(error: error.localizedDescription)
                }
        }
    }
    
    public func setNumberOfRetries(number : Int){
        self.retrier.numberOfRetries = number
    }
    // MARK: - Private methods
    
    private func resetNumberOfRetries() {
        self.retrier.numberOfRetries = 0
    }
    
    private func parseApiError(data: Data?) -> AlertMessage {
        let decoder = JSONDecoder()
        if let jsonData = data, let error = try? decoder.decode(NetworkError.self, from: jsonData) {
            return AlertMessage(title: "Error", body: error.key ?? error.message)
        }
        return AlertMessage(title: "Error", body: "Please try again later.")
    }
    
    // MARK: - Initialization
    
    public init(sessionManager: SessionManager = SessionManager(), retrier: RequestManagerRetrier = RequestManagerRetrier()) {
        self.sessionManager = sessionManager
        self.retrier = retrier
        self.sessionManager.retrier = self.retrier
    }
    
}

//MAARK:- URL Extension
extension URL {
    
    func getMimeType() -> String {
        
        let fileExtension = pathExtension as CFString
        guard let extUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, fileExtension, nil)?.takeUnretainedValue() else {
            return ""
        }
        
        guard let mimeUTI = UTTypeCopyPreferredTagWithClass(extUTI, kUTTagClassMIMEType) else {
            return ""
        }
        
        let mimeType = convertCfTypeToString(cfValue: mimeUTI) ?? ""
        //print("MimeType -> " + mimeType)
        return mimeType
    }
    
    private func convertCfTypeToString(cfValue: Unmanaged<CFString>!) -> String?{
        
        let value = Unmanaged.fromOpaque(cfValue.toOpaque()).takeUnretainedValue() as CFString
        if CFGetTypeID(value) == CFStringGetTypeID(){
            return value as String
        } else {
            return nil
        }
    }
}
