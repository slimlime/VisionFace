//
//  ViewController.swift
//  VisionFace
//
//  Created by 開発 on 2017/7/10.
//  Copyright © 2017 OOPer (NAGATA, Atsuyuki). All rights reserved.
//


import UIKit
import AVFoundation
import CoreImage
import ImageIO
import Photos
import Vision

//MARK:-

private func DegreesToRadians(_ degrees: CGFloat) -> CGFloat {return degrees * (.pi / 180)}

// create a CGImage with provided pixel buffer, pixel buffer must be uncompressed kCVPixelFormatType_32ARGB or kCVPixelFormatType_32BGRA
private func CreateCGImageFromCVPixelBuffer(_ pixelBuffer: CVPixelBuffer, _ imageOut: inout CGImage?) -> OSStatus {
    let err = noErr
    var bitmapInfo: CGBitmapInfo
    
    let sourcePixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    if kCVPixelFormatType_32ARGB == sourcePixelFormat {
        bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
    } else if kCVPixelFormatType_32BGRA == sourcePixelFormat {
        bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
    } else {
        return -95014 // only uncompressed pixel formats
    }
    
    let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let sourceBaseAddr = CVPixelBufferGetBaseAddress(pixelBuffer)!
    
    let colorspace = CGColorSpaceCreateDeviceRGB()
    
    let data = Data(bytes: sourceBaseAddr, count: sourceRowBytes * height)
    let provider = CGDataProvider(data: data as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: sourceRowBytes, space: colorspace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: true, intent: CGColorRenderingIntent.defaultIntent)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    
    imageOut = image
    return err
}

// utility used by newSquareOverlayedImageForFeatures for
func CreateCGBitmapContextForSize(_ size: CGSize) -> CGContext? {
    
    let bitmapBytesPerRow = Int(size.width * 4)
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil,
                            width: Int(size.width),
                            height: Int(size.height),
                            bitsPerComponent: 8,      // bits per component
        bytesPerRow: bitmapBytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.setAllowsAntialiasing(false)
    return context
}

//MARK:-

extension UIImage {
    
    func rotated(byDegrees degrees: CGFloat) -> UIImage! {
        // calculate the size of the rotated view's containing box for our drawing space
        let rotatedViewBox = UIView(frame: CGRect(x: 0, y: 0, width: self.size.width, height: self.size.height))
        let t = CGAffineTransform(rotationAngle: DegreesToRadians(degrees))
        rotatedViewBox.transform = t
        let rotatedSize = rotatedViewBox.frame.size
        
        // Create the bitmap context
        UIGraphicsBeginImageContext(rotatedSize)
        let bitmap = UIGraphicsGetCurrentContext()
        
        // Move the origin to the middle of the image so we will rotate and scale around the center.
        bitmap?.translateBy(x: rotatedSize.width/2, y: rotatedSize.height/2)
        
        //   // Rotate the image context
        bitmap?.rotate(by: DegreesToRadians(degrees))
        
        // Now, draw the rotated/scaled image into the context
        bitmap?.scaleBy(x: 1.0, y: -1.0)
        bitmap?.draw(self.cgImage!, in: CGRect(x: -self.size.width / 2, y: -self.size.height / 2, width: self.size.width, height: self.size.height))
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage
        
    }
    
}

//MARK:-

class ViewController: UIViewController, UIGestureRecognizerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    @IBOutlet private var previewView: UIView!
    @IBOutlet private var camerasControl: UISegmentedControl!
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var detectFaces: Bool = false
    private var videoDataOutputQueue: DispatchQueue?
    private var photoOutput: AVCapturePhotoOutput?
    private var flashView: UIView?
    private var square: UIImage!
    private var isUsingFrontFacingCamera: Bool = false
    private var faceDetector: CIDetector!
    private var beginGestureScale: CGFloat = 0.0
    private var effectiveScale: CGFloat = 0.0
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    private func setupAVCapture() {
        do {
            
            let session = AVCaptureSession()
            if UIDevice.current.userInterfaceIdiom == .phone {
                session.sessionPreset = .vga640x480
            } else {
                session.sessionPreset = .photo
            }
            
            // Select a video device, make an input
            let device = AVCaptureDevice.default(for: .video)
            let deviceInput = try AVCaptureDeviceInput(device: device!)
            
            isUsingFrontFacingCamera = false
            if session.canAddInput(deviceInput) {
                session.addInput(deviceInput)
            }
            
            // Make a still image output
            photoOutput = AVCapturePhotoOutput()
            if session.canAddOutput(photoOutput!) {
                session.addOutput(photoOutput!)
            }

            // Make a video data output
            videoDataOutput = AVCaptureVideoDataOutput()
            
            // we want BGRA, both CoreGraphics and OpenGL work well with 'BGRA'
            let rgbOutputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCMPixelFormat_32BGRA]
            videoDataOutput!.videoSettings = rgbOutputSettings
            videoDataOutput!.alwaysDiscardsLateVideoFrames = true // discard if the data output queue is blocked (as we process the still image)
            
            // create a serial dispatch queue used for the sample buffer delegate as well as when a still image is captured
            // a serial dispatch queue must be used to guarantee that video frames will be delivered in order
            // see the header doc for setSampleBufferDelegate:queue: for more information
            videoDataOutputQueue = DispatchQueue(label: "VideoDataOutputQueue", attributes: [])
            videoDataOutput!.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
            
            if session.canAddOutput(videoDataOutput!) {
                session.addOutput(videoDataOutput!)
            }
            videoDataOutput!.connection(with: .video)?.isEnabled = false
            
            effectiveScale = 1.0;
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer!.backgroundColor = UIColor.black.cgColor
            previewLayer!.videoGravity = .resizeAspect
            let rootLayer = previewView.layer
            rootLayer.masksToBounds = true
            previewLayer!.frame = rootLayer.bounds
            rootLayer.addSublayer(previewLayer!)
            session.startRunning()
            
        } catch let error as NSError {
            let alertController = UIAlertController(title: "Failed with error \(error.code)", message: error.description, preferredStyle: .alert)
            let dismissAction = UIAlertAction(title: "Dismiss", style: .cancel, handler: nil)
            alertController.addAction(dismissAction)
            self.present(alertController, animated: true, completion: nil)
            self.teardownAVCapture()
        }
    }
    
    // clean up capture setup
    private func teardownAVCapture() {
        videoDataOutput = nil
        if videoDataOutputQueue != nil {
            videoDataOutputQueue = nil
        }
        photoOutput = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
    }
    
    // utility routing used during image capture to set up capture orientation
    private func avOrientation(for deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        var result = AVCaptureVideoOrientation(rawValue: deviceOrientation.rawValue)!
        if deviceOrientation == UIDeviceOrientation.landscapeLeft {
            result = AVCaptureVideoOrientation.landscapeRight
        } else if deviceOrientation == UIDeviceOrientation.landscapeRight {
            result = AVCaptureVideoOrientation.landscapeLeft
        }
        return result
    }
    
    // utility routine to create a new image with the red square overlay with appropriate orientation
    // and return the new composited image which can be saved to the camera roll
    private func newSquareOverlayedImage(for features: [CIFeature],
                                         inCGImage backgroundImage: CGImage,
                                         withOrientation orientation: UIDeviceOrientation,
                                         frontFacing isFrontFacing: Bool) -> CGImage
    {
        let backgroundImageRect = CGRect(x: 0, y: 0, width: backgroundImage.width, height: backgroundImage.height)
        let bitmapContext = CreateCGBitmapContextForSize(backgroundImageRect.size)
        bitmapContext?.clear(backgroundImageRect)
        bitmapContext?.draw(backgroundImage, in: backgroundImageRect)
        var rotationDegrees: CGFloat = 0.0
        
        switch orientation {
        case .portrait:
            rotationDegrees = -90.0
        case .portraitUpsideDown:
            rotationDegrees = 90.0
        case .landscapeLeft:
            if isFrontFacing {
                rotationDegrees = 180.0
            } else {
                rotationDegrees = 0.0
            }
        case .landscapeRight:
            if isFrontFacing {
                rotationDegrees = 0.0
            } else {
                rotationDegrees = 180.0
            }
        case .faceUp, .faceDown:
            break
        default:
            break // leave the layer in its last known orientation
        }
        let rotatedSquareImage = square.rotated(byDegrees: rotationDegrees)!
        
        // features found by the face detector
        for ff in features {
            let faceRect = ff.bounds
            bitmapContext?.draw(rotatedSquareImage.cgImage!, in: faceRect)
        }
        let returnImage = bitmapContext?.makeImage()!
        
        return returnImage!
    }
    
    // utility routine used after taking a still image to write the resulting image to the camera roll
    @discardableResult
    private func writeCGImageToCameraRoll(_ cgImage: CGImage, withMetadata metadata: [String: Any]) -> Bool {
        var success = true
        bail: do {
            let destinationData = CFDataCreateMutable(kCFAllocatorDefault, 0)
            guard let destination = CGImageDestinationCreateWithData(destinationData!,
                                                                     "public.jpeg" as CFString,
                                                                     1,
                                                                     nil)
                else {
                    success = false
                    break bail
            }
            
            let JPEGCompQuality: Float = 0.85 // JPEGHigherQuality
            
            var optionsDict = metadata
            optionsDict[kCGImageDestinationLossyCompressionQuality as String] = JPEGCompQuality
            CGImageDestinationAddImage(destination, cgImage, optionsDict as CFDictionary?)
            
            success = CGImageDestinationFinalize(destination)
            
            guard success else {break bail}
            
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: destinationData as Data!, options: nil)
                request.creationDate = Date()
            }) {success, error in
                if let error = error as NSError? {
                    self.displayErrorOnMainQueue(error, withMessage: "Save to camera roll failed")
                }
            }
        }
        return success
    }
    
    // utility routine to display error aleart if takePicture fails
    private func displayErrorOnMainQueue(_ error: NSError, withMessage message: String) {
        DispatchQueue.main.async {
            let alertController = UIAlertController(title:  "\(message) (\(error.code)", message: error.localizedDescription, preferredStyle: .alert)
            let dismissAction = UIAlertAction(title: "Dismiss", style: .cancel, handler: nil)
            alertController.addAction(dismissAction)
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    // main action method to take a still image -- if face detection has been turned on and a face has been detected
    // the square overlay will be composited on top of the captured image and saved to the camera roll
    @IBAction func takePicture(_: Any) {
        // Find out the current orientation and tell the still image output.
        guard let photoConnection = photoOutputVideoConnection else {
            print("photoOutputVideoConnection == nil");return
        }
        let curDeviceOrientation = UIDevice.current.orientation
        let avcaptureOrientation = self.avOrientation(for: curDeviceOrientation)
        photoConnection.videoOrientation = avcaptureOrientation
        photoConnection.videoScaleAndCropFactor = effectiveScale
        
        let doingFaceDetection = detectFaces && (effectiveScale == 1.0)
        
        // set the appropriate pixel format / image type output setting depending on if we'll need an uncompressed image for
        // the possiblity of drawing the red square over top or if we're just writing a jpeg to the camera roll which is the trival case
        var outputFormat: [String: Any] = [:]
        if doingFaceDetection {
            outputFormat = [kCVPixelBufferPixelFormatTypeKey as String: kCMPixelFormat_32BGRA]
        } else {
            outputFormat = [AVVideoCodecKey: AVVideoCodecType.jpeg]
        }
        let settings = AVCapturePhotoSettings(format: outputFormat)
        
        photoOutput?.capturePhoto(with: settings, delegate: self)
    }
    
    // turn on/off face detection
    @IBAction func toggleFaceDetection(_ sender: UISwitch) {
        detectFaces = sender.isOn
        videoDataOutput?.connection(with: .video)?.isEnabled = detectFaces
        if !detectFaces {
            DispatchQueue.main.async {
                // clear out any squares currently displaying.
                #if USES_CIDETECTOR
                    self.drawFaceBoxes(for: [CIFeature](), forVideoBox: .zero, orientation: .portrait)
                #else
                    self.drawFaceBoxes(for: [VNFaceObservation](), forVideoBox: .zero, orientation: .portrait)
                #endif
            }
        }
    }
    
    // find where the video box is positioned within the preview layer based on the video size and gravity
    private static func videoPreviewBox(for gravity: AVLayerVideoGravity, frameSize: CGSize, apertureSize: CGSize) -> CGRect {
        let apertureRatio = apertureSize.height / apertureSize.width
        let viewRatio = frameSize.width / frameSize.height
        
        var size = CGSize.zero
        switch gravity {
        case .resizeAspectFill:
            if viewRatio > apertureRatio {
                size.width = frameSize.width
                size.height = apertureSize.width * (frameSize.width / apertureSize.height)
            } else {
                size.width = apertureSize.height * (frameSize.height / apertureSize.width)
                size.height = frameSize.height
            }
        case .resizeAspect:
            if viewRatio > apertureRatio {
                size.width = apertureSize.height * (frameSize.height / apertureSize.width)
                size.height = frameSize.height;
            } else {
                size.width = frameSize.width;
                size.height = apertureSize.width * (frameSize.width / apertureSize.height);
            }
        case .resize:
            size.width = frameSize.width
            size.height = frameSize.height
        default:
            break
        }
        
        var videoBox: CGRect = CGRect()
        videoBox.size = size;
        if size.width < frameSize.width {
            videoBox.origin.x = (frameSize.width - size.width) / 2
        } else {
            videoBox.origin.x = (size.width - frameSize.width) / 2
        }
        
        if size.height < frameSize.height {
            videoBox.origin.y = (frameSize.height - size.height) / 2
        } else {
            videoBox.origin.y = (size.height - frameSize.height) / 2
        }
        
        return videoBox;
    }
    
    // called asynchronously as the capture output is capturing sample buffers, this method asks the face detector (if on)
    // to detect features and for each draw the red square in a layer and set appropriate orientation
    private func drawFaceBoxes(for features: [CIFeature], forVideoBox clap: CGRect, orientation: UIDeviceOrientation) {
        let sublayers = previewLayer?.sublayers ?? []
        let sublayersCount = sublayers.count
        var currentSublayer = 0
        let featuresCount = features.count
        
        CATransaction.begin()
        CATransaction.setValue(true, forKey: kCATransactionDisableActions)
        
        // hide all the face layers
        for layer in sublayers {
            if layer.name == "FaceLayer" {
                layer.isHidden = true
            }
        }
        
        if featuresCount == 0 || !detectFaces {
            CATransaction.commit()
            return // early bail.
        }
        
        let parentFrameSize = previewView.frame.size;
        let gravity = previewLayer?.videoGravity
        let isMirrored = previewLayer?.connection?.isVideoMirrored ?? false
        let previewBox = ViewController.videoPreviewBox(for: gravity!,
                                                                 frameSize: parentFrameSize,
                                                                 apertureSize: clap.size)
        
        for ff in features as! [CIFaceFeature] {
            // find the correct position for the square layer within the previewLayer
            // the feature box originates in the bottom left of the video frame.
            // (Bottom right if mirroring is turned on)
            var faceRect = ff.bounds
            
            // flip preview width and height
            var temp = faceRect.size.width
            faceRect.size.width = faceRect.size.height
            faceRect.size.height = temp
            temp = faceRect.origin.x
            faceRect.origin.x = faceRect.origin.y
            faceRect.origin.y = temp
            // scale coordinates so they fit in the preview box, which may be scaled
            let widthScaleBy = previewBox.size.width / clap.size.height
            let heightScaleBy = previewBox.size.height / clap.size.width
            faceRect.size.width *= widthScaleBy
            faceRect.size.height *= heightScaleBy
            faceRect.origin.x *= widthScaleBy
            faceRect.origin.y *= heightScaleBy
            
            if isMirrored {
                faceRect = faceRect.offsetBy(dx: previewBox.origin.x + previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), dy: previewBox.origin.y)
            } else {
                faceRect = faceRect.offsetBy(dx: previewBox.origin.x, dy: previewBox.origin.y)
            }
            
            var featureLayer: CALayer? = nil
            
            // re-use an existing layer if possible
            while featureLayer == nil && (currentSublayer < sublayersCount) {
                let currentLayer = sublayers[currentSublayer];currentSublayer += 1
                if currentLayer.name == "FaceLayer" {
                    featureLayer = currentLayer
                    currentLayer.isHidden = false
                }
            }
            
            // create a new one if necessary
            if featureLayer == nil {
                featureLayer = CALayer()
                featureLayer!.contents = square.cgImage
                featureLayer!.name = "FaceLayer"
                previewLayer?.addSublayer(featureLayer!)
            }
            featureLayer!.frame = faceRect
            
            switch orientation {
            case .portrait:
                featureLayer!.setAffineTransform(CGAffineTransform(rotationAngle: DegreesToRadians(0.0)))
            case .portraitUpsideDown:
                featureLayer!.setAffineTransform(CGAffineTransform(rotationAngle: DegreesToRadians(180.0)))
            case .landscapeLeft:
                featureLayer!.setAffineTransform(CGAffineTransform(rotationAngle: DegreesToRadians(90.0)))
            case .landscapeRight:
                featureLayer!.setAffineTransform(CGAffineTransform(rotationAngle: DegreesToRadians(-90.0)))
            case .faceUp, .faceDown:
                break
            default:
                
                break // leave the layer in its last known orientation//        }
            }
        }
        
        CATransaction.commit()
    }
    private func drawFaceBoxes(for observations: [VNFaceObservation], forVideoBox clap: CGRect, orientation: UIDeviceOrientation) {
        let sublayers = previewLayer?.sublayers ?? []
        let featuresCount = observations.count
        
        CATransaction.begin()
        CATransaction.setValue(true, forKey: kCATransactionDisableActions)
        
        // hide all the face layers
        for layer in sublayers {
            if layer.name == "FaceRectLayer" {
                layer.isHidden = true
            }
        }
        
        if featuresCount == 0 || !detectFaces {
            CATransaction.commit()
            return // early bail.
        }
        
        let parentFrameSize = previewView.frame.size;
        let gravity = previewLayer?.videoGravity
        let isMirrored = previewLayer?.connection?.isVideoMirrored ?? false
        let previewBox = ViewController.videoPreviewBox(for: gravity!,
                                                        frameSize: parentFrameSize,
                                                        apertureSize: clap.size)
        
        for observation in observations {
            // find the correct position for the square layer within the previewLayer
            // the feature box originates in the bottom left of the video frame.
            // (Bottom right if mirroring is turned on)
            var faceRect = observation.boundingBox
            print("###FaceRect:",faceRect)
            // flip preview width and height
            if isMirrored {
                faceRect.origin.x = 1 - faceRect.origin.x - faceRect.size.width
            }
            faceRect.origin.y = 1 - faceRect.size.height - faceRect.origin.y
            // scale coordinates so they fit in the preview box, which may be scaled
            faceRect.size.width *= previewBox.width
            faceRect.size.height *= previewBox.height
            faceRect.origin.x = faceRect.origin.x * previewBox.width + previewBox.origin.x
            faceRect.origin.y = previewBox.origin.y + faceRect.origin.y * previewBox.height
            let points: [CGPoint] = [
                CGPoint(x: faceRect.origin.x, y: faceRect.origin.y),
                CGPoint(x: faceRect.origin.x + faceRect.size.width, y: faceRect.origin.y),
                CGPoint(x: faceRect.origin.x + faceRect.size.width, y: faceRect.origin.y + faceRect.size.height),
                CGPoint(x: faceRect.origin.x, y: faceRect.origin.y + faceRect.size.height),
            ]

            var featureLayer: CAShapeLayer? = nil
            
            let path = UIBezierPath()
            path.move(to: points[0])
            path.addLine(to: points[1])
            path.addLine(to: points[2])
            path.addLine(to: points[3])
            path.close()
            
            // re-use an existing layer if possible
            for currentSublayer in sublayers
                where currentSublayer.name == "FaceRectLayer"
            {
                let currentLayer = currentSublayer as! CAShapeLayer
                featureLayer = currentLayer
                currentLayer.isHidden = false
                break
            }
            
            // create a new one if necessary
            if featureLayer == nil {
                let shapeLayer = CAShapeLayer()
                shapeLayer.strokeColor = UIColor.red.cgColor
                shapeLayer.lineWidth = 4.0
                shapeLayer.fillColor = UIColor.clear.cgColor
                shapeLayer.name = "FaceRectLayer"
                featureLayer = shapeLayer
                previewLayer?.addSublayer(featureLayer!)
            }
            featureLayer!.path = path.cgPath
            featureLayer!.frame = previewView.frame
//            featureLayer!.frame = faceRect
            
//            switch orientation {
//            case .portrait:
//                featureLayer!.setAffineTransform(CGAffineTransform(rotationAngle: DegreesToRadians(0.0)))
//            case .portraitUpsideDown:
//                featureLayer!.setAffineTransform(CGAffineTransform(rotationAngle: DegreesToRadians(180.0)))
//            case .landscapeLeft:
//                featureLayer!.setAffineTransform(CGAffineTransform(rotationAngle: DegreesToRadians(90.0)))
//            case .landscapeRight:
//                featureLayer!.setAffineTransform(CGAffineTransform(rotationAngle: DegreesToRadians(-90.0)))
//            case .faceUp, .faceDown:
//                break
//            default:
//
//                break // leave the layer in its last known orientation//        }
//            }
        }
        
        CATransaction.commit()
    }

    private func exifOrientation(from curDeviceOrientation: UIDeviceOrientation) -> Int {
        var exifOrientation: Int = 0
        
        /* kCGImagePropertyOrientation values
         The intended display orientation of the image. If present, this key is a CFNumber value with the same value as defined
         by the TIFF and EXIF specifications -- see enumeration of integer constants.
         The value specified where the origin (0,0) of the image is located. If not present, a value of 1 is assumed.
         
         used when calling featuresInImage: options: The value for this key is an integer NSNumber from 1..8 as found in kCGImagePropertyOrientation.
         If present, the detection will be done based on that orientation but the coordinates in the returned features will still be based on those of the image. */
        
        
        let PHOTOS_EXIF_0ROW_TOP_0COL_LEFT            = 1 //   1  =  0th row is at the top, and 0th column is on the left (THE DEFAULT).
        //let PHOTOS_EXIF_0ROW_TOP_0COL_RIGHT            = 2 //   2  =  0th row is at the top, and 0th column is on the right.
        let PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT      = 3 //   3  =  0th row is at the bottom, and 0th column is on the right.
        //let PHOTOS_EXIF_0ROW_BOTTOM_0COL_LEFT       = 4 //   4  =  0th row is at the bottom, and 0th column is on the left.
        //let PHOTOS_EXIF_0ROW_LEFT_0COL_TOP          = 5 //   5  =  0th row is on the left, and 0th column is the top.
        let PHOTOS_EXIF_0ROW_RIGHT_0COL_TOP         = 6 //   6  =  0th row is on the right, and 0th column is the top.
        //let PHOTOS_EXIF_0ROW_RIGHT_0COL_BOTTOM      = 7 //   7  =  0th row is on the right, and 0th column is the bottom.
        let PHOTOS_EXIF_0ROW_LEFT_0COL_BOTTOM       = 8  //   8  =  0th row is on the left, and 0th column is the bottom.
        
        switch curDeviceOrientation {
        case .portraitUpsideDown:  // Device oriented vertically, home button on the top
            exifOrientation = PHOTOS_EXIF_0ROW_LEFT_0COL_BOTTOM
        case .landscapeLeft:       // Device oriented horizontally, home button on the right
            if isUsingFrontFacingCamera {
                exifOrientation = PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT
            } else {
                exifOrientation = PHOTOS_EXIF_0ROW_TOP_0COL_LEFT
            }
        case .landscapeRight:      // Device oriented horizontally, home button on the left
            if isUsingFrontFacingCamera {
                exifOrientation = PHOTOS_EXIF_0ROW_TOP_0COL_LEFT
            } else {
                exifOrientation = PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT
            }
        case .portrait:            // Device oriented vertically, home button on the bottom
            fallthrough
        default:
            exifOrientation = PHOTOS_EXIF_0ROW_RIGHT_0COL_TOP
        }
        return exifOrientation
    }
    private func cgImagePropertyOrientation(from deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
        return CGImagePropertyOrientation(rawValue: UInt32(exifOrientation(from: deviceOrientation)))!
    }
    
    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        #if USES_CIDETECTOR
            detectFacesWithCIDetector(for: captureOutput, sampleBuffer: sampleBuffer, from: connection)
        #else
            detectFacesWithVision(for: captureOutput, sampleBuffer: sampleBuffer, from: connection)
        #endif
    }
    private func detectFacesWithCIDetector(for captureOutput: AVCaptureOutput, sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // got an image
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
        let attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate) as! [String: Any]?
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer, options: attachments)
        
        let curDeviceOrientation = UIDevice.current.orientation
        let exifOrientation = self.exifOrientation(from: curDeviceOrientation)
        
        let imageOptions = [CIDetectorImageOrientation: exifOrientation]
        let features = faceDetector.features(in: ciImage, options: imageOptions)
        
        // get the clean aperture
        // the clean aperture is a rectangle that defines the portion of the encoded pixel dimensions
        // that represents image data valid for display.
        let fdesc = CMSampleBufferGetFormatDescription(sampleBuffer)!
        let clap = CMVideoFormatDescriptionGetCleanAperture(fdesc, false /*originIsTopLeft == false*/)
        
        DispatchQueue.main.async {
            self.drawFaceBoxes(for: features, forVideoBox: clap, orientation: curDeviceOrientation)
        }
    }
    private func detectFacesWithVision(for captureOutput: AVCaptureOutput, sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // got an image
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
        let curDeviceOrientation = UIDevice.current.orientation
        let orientation = cgImagePropertyOrientation(from: curDeviceOrientation)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        
        let request = VNDetectFaceRectanglesRequest {request, error in
            let observations = request.results as! [VNFaceObservation]
            
            // get the clean aperture
            // the clean aperture is a rectangle that defines the portion of the encoded pixel dimensions
            // that represents image data valid for display.
            let fdesc = CMSampleBufferGetFormatDescription(sampleBuffer)!
            let clap = CMVideoFormatDescriptionGetCleanAperture(fdesc, false /*originIsTopLeft == false*/)
            
            DispatchQueue.main.async {
                self.drawFaceBoxes(for: observations, forVideoBox: clap, orientation: curDeviceOrientation)
            }
        }
        do {
            try handler.perform([request])
        } catch {
            print(error)
        }
    }

    deinit {
        self.teardownAVCapture()
    }
    
    // use front/back camera
    @IBAction func switchCameras(_: Any) {
        let desiredPosition: AVCaptureDevice.Position
        if isUsingFrontFacingCamera {
            desiredPosition = AVCaptureDevice.Position.back
        } else {
            desiredPosition = AVCaptureDevice.Position.front
        }
        
        func configInput(for device: AVCaptureDevice) {
            previewLayer?.session?.beginConfiguration()
            var input: AVCaptureDeviceInput?
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {}
            for oldInput in previewLayer?.session?.inputs as [AVCaptureInput]! ?? [] {
                previewLayer?.session?.removeInput(oldInput)
            }
            previewLayer?.session?.addInput(input!)
            previewLayer?.session?.commitConfiguration()
        }
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: desiredPosition) {
            configInput(for: device)
        }
        isUsingFrontFacingCamera = !isUsingFrontFacingCamera
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Release any cached data, images, etc that aren't in use.
    }
    
    //MARK: - View lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        self.setupAVCapture()
        square = UIImage(named: "squarePNG")
        let detectorOptions: [String: Any] = [CIDetectorAccuracy: CIDetectorAccuracyLow]
        faceDetector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: detectorOptions)
        //
        requestPhotoLibraryAuthentication()
    }
    
    //- (void)viewDidUnload
    //{
    //    [super viewDidUnload];
    //    // Release any retained subviews of the main view.
    //    // e.g. self.myOutlet = nil;
    //}
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    //- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
    //{
    //    // Return YES for supported orientations
    //    return (interfaceOrientation == UIInterfaceOrientationPortrait);
    //}
    override var supportedInterfaceOrientations : UIInterfaceOrientationMask {
        return .portrait
    }
    override var preferredInterfaceOrientationForPresentation : UIInterfaceOrientation {
        return .portrait
    }
    
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPinchGestureRecognizer {
            beginGestureScale = effectiveScale
        }
        return true
    }
    
    // scale image depending on users pinch gesture
    @IBAction func handlePinchGesture(_ recognizer: UIPinchGestureRecognizer) {
        var allTouchesAreOnThePreviewLayer = true
        let numTouches = recognizer.numberOfTouches
        for i in 0..<numTouches {
            let location = recognizer.location(ofTouch: i, in: previewView)
            let convertedLocation = previewLayer!.convert(location, from: previewLayer!.superlayer)
            if !previewLayer!.contains(convertedLocation) {
                allTouchesAreOnThePreviewLayer = false
                break
            }
        }
        
        if allTouchesAreOnThePreviewLayer {
            effectiveScale = beginGestureScale * recognizer.scale
            if effectiveScale < 1.0 {
                effectiveScale = 1.0
            }
            let maxScaleAndCropFactor = photoOutputVideoConnection?.videoMaxScaleAndCropFactor
            if effectiveScale > maxScaleAndCropFactor! {
                effectiveScale = maxScaleAndCropFactor!
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.025)
            previewLayer!.setAffineTransform(CGAffineTransform(scaleX: effectiveScale, y: effectiveScale))
            CATransaction.commit()
        }
    }
    
    //MARK: ### compatibility...
    
    private var photoOutputVideoConnection: AVCaptureConnection? {
        return photoOutput?.connection(with: .video)
    }

    //### request for PhotoLibrary authentication (simplified)
    private func requestPhotoLibraryAuthentication() {
        let status = PHPhotoLibrary.authorizationStatus()
        switch status {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization {status in
                //### For practical usage, show alert, update UI, guide to settings...
            }
        default:
            break
        }
    }
}

@available(iOS 10.0, *)
extension ViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // do flash bulb like animation
        flashView = UIView(frame: previewView!.frame)
        flashView!.backgroundColor = .white
        flashView!.alpha = 0.0
        self.view.window?.addSubview(flashView!)
        
        UIView.animate(withDuration: 0.4, animations: {
            self.flashView?.alpha = 1.0
        })
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        UIView.animate(withDuration: 0.4,
                       animations: {
                        self.flashView?.alpha = 0.0
        },
                       completion: {finished in
                        self.flashView?.removeFromSuperview()
                        self.flashView = nil;
        })
    }
    @available(iOS 11.0, *)
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error as NSError? {
            self.displayErrorOnMainQueue(error, withMessage: "Take picture failed")
        } else {
            let doingFaceDetection = detectFaces && (effectiveScale == 1.0)
            
            if doingFaceDetection {
                // Got an image.
                let pixelBuffer = photo.pixelBuffer!
                let attachments = photo.metadata
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer, options: attachments)
                
                var imageOptions: [String: Any] = [:]
                if let orientation = attachments[kCGImagePropertyOrientation as String] {
                    imageOptions = [CIDetectorImageOrientation: orientation]
                }
                
                // when processing an existing frame we want any new frames to be automatically dropped
                // queueing this block to execute on the videoDataOutputQueue serial queue ensures this
                // see the header doc for setSampleBufferDelegate:queue: for more information
                self.videoDataOutputQueue!.sync {
                    
                    // get the array of CIFeature instances in the given image with a orientation passed in
                    // the detection will be done based on the orientation but the coordinates in the returned features will
                    // still be based on those of the image.
                    let features = self.faceDetector.features(in: ciImage, options: imageOptions)
                    guard let srcImage = photo.cgImageRepresentation()?.takeUnretainedValue() else {
                        fatalError()
                    }
                    
                    let curDeviceOrientation = UIDevice.current.orientation
                    let cgImageResult = self.newSquareOverlayedImage(for: features, inCGImage: srcImage, withOrientation: curDeviceOrientation, frontFacing: self.isUsingFrontFacingCamera)
                    let attachments = photo.metadata
                    self.writeCGImageToCameraRoll(cgImageResult, withMetadata: attachments)
                    
                }
                
            } else {
                // trivial simple JPEG case
                let jpegData = photo.fileDataRepresentation()
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: jpegData!, options: nil)
                    request.creationDate = Date()
                }) {success, error in
                    if let error = error as NSError? {
                        self.displayErrorOnMainQueue(error, withMessage: "Save to camera roll failed")
                    }
                }
            }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        // clean up resources used for photo capturing...
    }
    //### This app does not capture LivePhotos.
    //    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
    //        //
    //    }
    //    func photoOutput(_ output: AVCapturePhotoOutput, didFinishRecordingLivePhotoMovieForEventualFileAt outputFileURL: URL, resolvedSettings: AVCaptureResolvedPhotoSettings) {
    //        //
    //    }
//    @available(iOS, deprecated: 11.0)
//    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?, previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?, resolvedSettings: AVCaptureResolvedPhotoSettings, bracketSettings: AVCaptureBracketedStillImageSettings?, error: Error?) {
//        //
//    }
    //### This app does not use raw photo.
    //    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingRawPhoto rawSampleBuffer: CMSampleBuffer?, previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?, resolvedSettings: AVCaptureResolvedPhotoSettings, bracketSettings: AVCaptureBracketedStillImageSettings?, error: Error?) {
    //        //
    //    }
}

