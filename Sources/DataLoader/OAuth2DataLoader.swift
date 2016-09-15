//
//  OAuth2DataLoader.swift
//  OAuth2
//
//  Created by Pascal Pfiffner on 8/31/16.
//  Copyright 2016 Pascal Pfiffner
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
#if !NO_MODULE_IMPORT
import Base
import Flows
#endif


/**
A class that makes loading data from a protected endpoint easier.
*/
open class OAuth2DataLoader: OAuth2Requestable {
	
	/// The OAuth2 instance used for OAuth2 access tokvarretrieval.
	public let oauth2: OAuth2
	
	/// If set to true, a 403 is treated as a 401. The default is false.
	public var alsoIntercept403: Bool = false
	
	
	public init(oauth2: OAuth2) {
		self.oauth2 = oauth2
		super.init(logger: oauth2.logger)
	}
	
	
	// MARK: - Make Requests
	
	/// Our FIFO queue.
	private var enqueued: [OAuth2DataRequest]?
	
	private var isAuthorizing = false
	
	/**
	Overriding this method: it intercepts `unauthorizedClient` errors, stops and enqueues all calls, starts the authorization and, upon
	success, resumes all enqueued calls.
	
	The callback looks terrifying but is actually easy to use, like so:
	
	    perform(request: req) { dataStatusResponse in
	        do {
	            let (data, status) = try dataStatusResponse()
	            // do what you must with `data` as Data and `status` as Int
	        }
	        catch let error {
	            // the request failed because of `error`
	        }
	    }
	
	Easy, right?
	
	- parameter request:  The request to execute
	- parameter callback: The callback to call when the request completes/fails. Looks terrifying, see above on how to use it
	*/
	override open func perform(request: URLRequest, callback: @escaping ((OAuth2Response) -> Void)) {
		perform(request: request, retry: true, callback: callback)
	}
	
	open func perform(request: URLRequest, retry: Bool, callback: @escaping ((OAuth2Response) -> Void)) {
		guard !isAuthorizing else {
			enqueue(request: request, callback: callback)
			return
		}
		
		super.perform(request: request) { response in
			do {
				if self.alsoIntercept403, 403 == response.response.statusCode {
					throw OAuth2Error.unauthorizedClient
				}
				let _ = try response.responseData()
				callback(response)
			}
			
			// not authorized; stop and enqueue all requests, start authorization once, then re-try all enqueued requests
			catch OAuth2Error.unauthorizedClient {
				if retry {
					self.enqueue(request: request, callback: callback)
					self.attemptToAuthorize()
				}
				else {
					callback(response)
				}
			}
				
			// some other error, pass along
			catch {
				callback(response)
			}
		}
	}
	
	open func attemptToAuthorize() {
		if !isAuthorizing {
			isAuthorizing = true
			oauth2.authorize() { json, error in
				self.isAuthorizing = false
				
				// dequeue all if we're authorized, throw all away if something went wrong
				if let error = error {
					self.throwAllAway(with: error)
				}
				else {
					self.retryAll()
				}
			}
		}
	}
	
	
	// MARK: - Queue
	
	func enqueue(request: URLRequest, callback: @escaping ((OAuth2Response) -> Void)) {
		enqueue(request: OAuth2DataRequest(request: request, callback: callback))
	}
	
	func enqueue(request: OAuth2DataRequest) {
		if nil == enqueued {
			enqueued = [request]
		}
		else {
			enqueued!.append(request)
		}
	}
	
	func dequeueAndApply(closure: ((OAuth2DataRequest) -> Void)) {
		guard let enq = enqueued else {
			return
		}
		enqueued = nil
		enq.forEach(closure)
	}
	
	func retryAll() {
		dequeueAndApply() { req in
			var request = req.request
			request.sign(with: oauth2)
			self.perform(request: request, retry: false, callback: req.callback)
		}
	}
	
	func throwAllAway(with error: OAuth2Error) {
		dequeueAndApply() { req in
			let res = OAuth2Response(data: nil, request: req.request, response: HTTPURLResponse(), error: error)
			req.callback(res)
		}
	}
}

