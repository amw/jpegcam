package {
  /* Webcam library for capturing JPEG images and submitting to a server */
  /* Copyright (c) 2008 - 2009 Joseph Huckaby <jhuckaby@goldcartridge.com> */
  /* Licensed under the GNU Lesser Public License */
  /* http://www.gnu.org/licenses/lgpl.html */

  import flash.display.LoaderInfo;
  import flash.display.Sprite;
  import flash.display.StageAlign;
  import flash.display.StageScaleMode;
  import flash.display.Bitmap;
  import flash.display.BitmapData;
  import flash.events.*;
  import flash.utils.*;
  import flash.media.Camera;
  import flash.media.Video;
  import flash.external.ExternalInterface;
  import flash.net.*;
  import flash.system.Security;
  import flash.system.SecurityPanel;
  import flash.media.Sound;
  import flash.media.SoundChannel;
  import flash.geom.Matrix;
  import com.adobe.images.JPGEncoder;

  public class Webcam extends Sprite {
    private var video:Video;
    private var snd:Sound;
    private var channel:SoundChannel = new SoundChannel();
    private var jpeg_quality:int;
    private var video_width:int;
    private var video_height:int;
    private var server_width:int;
    private var server_height:int;
    private var server_flip:Boolean;
    private var resize_needed:Boolean;
    private var camera:Camera;
    private var capture_data:BitmapData;
    private var display_data:BitmapData;
    private var display_bmp:Bitmap;
    private var url:String;
    private var http_status:int;
    private var stealth:Boolean;

    public function Webcam() {
      // class constructor
      flash.system.Security.allowDomain("*");
      var flashvars:Object = LoaderInfo(this.root.loaderInfo).parameters;
      video_width = Math.floor(flashvars.width);
      video_height = Math.floor(flashvars.height);
      server_width = Math.floor(flashvars.server_width);
      server_height = Math.floor(flashvars.server_height);
      server_flip = 1 == flashvars.server_flip
      resize_needed =
        video_width != server_width || video_height != server_height

      stage.scaleMode = StageScaleMode.NO_SCALE;
      stage.align = StageAlign.TOP_LEFT;
      stage.stageWidth = video_width;
      stage.stageHeight = video_height;

      // Hack to auto-select iSight camera on Mac
      // (JPEGCam Issue #5, submitted by manuel.gonzalez.noriega)
      var cameraIdx:int = -1;
      for (var i:int = 0, len:int = Camera.names.length; i < len; i++) {
        if (Camera.names[i] == "USB Video Class Video") {
          cameraIdx = i;
          i = len;
        }
      }

      if (cameraIdx > -1) {
        camera = Camera.getCamera(String(cameraIdx));
      }
      else {
        camera = Camera.getCamera();
      }

      if (camera != null) {
        camera.addEventListener(ActivityEvent.ACTIVITY, activityHandler);
        camera.addEventListener(StatusEvent.STATUS, statusHandler);
        video = new Video(
          Math.max(video_width, server_width),
          Math.max(video_height, server_height));
        video.attachCamera(camera);
        addChild(video);

        if ((video_width < server_width) && (video_height < server_height)) {
          video.scaleX = video_width / server_width;
          video.scaleY = video_height / server_height;
        }

        //flip video
        video.scaleX *= -1;
        video.x = video.width;

        camera.setQuality(0, 100);
        camera.setKeyFrameInterval(10);
        camera.setMode(
          Math.max(video_width, server_width),
          Math.max(video_height, server_height),
          30);

        // do not detect motion (may help reduce CPU usage)
        camera.setMotionLevel(100);

        ExternalInterface.addCallback('_snap', snap);
        ExternalInterface.addCallback('_configure', configure);
        ExternalInterface.addCallback('_upload', upload);
        ExternalInterface.addCallback('_reset', reset);

        if (flashvars.shutter_enabled == 1) {
          snd = new Sound();
          snd.load(new URLRequest(flashvars.shutter_url));
        }

        jpeg_quality = 90;

        capture_data = new BitmapData(
          Math.max(video_width, server_width),
          Math.max(video_height, server_height));
        display_data = new BitmapData(video_width, video_height);
        display_bmp = new Bitmap(display_data);

        ExternalInterface.call(
          'webcam.flash_notify', 'flashLoadComplete', !camera.muted);
      }
      else {
        debug("No camera was detected.");
        ExternalInterface.call(
          'webcam.flash_notify', "error", "No camera was detected.");
      }
    }

    public function set_quality(new_quality:int):void {
      // set JPEG image quality
      if (new_quality < 0) new_quality = 0;
      if (new_quality > 100) new_quality = 100;
      jpeg_quality = new_quality;
    }

    public function configure(panel:String = SecurityPanel.CAMERA):void {
      // show configure dialog inside flash movie
      Security.showSettings(panel);

      // When the security panel is visible the stage doesn't receive
      // mouse events. We can wait for a mouse move event to notify javascript
      // about the panel being closed.
      stage.addEventListener(MouseEvent.MOUSE_MOVE, onMouseMove);
    }

    private function onMouseMove(e:MouseEvent):void {
      // flash player sends mouseMove event with coordinates outside the stage
      // when user moves his mouse outside the stage even when the privacy
      // panel is displayed
      if (e.stageX >= 0 && e.stageX < stage.stageWidth &&
          e.stageY >= 0 && e.stageY < stage.stageHeight
      ) {
        stage.removeEventListener(MouseEvent.MOUSE_MOVE, onMouseMove);
        debug("Privacy panel closed.");
        ExternalInterface.call('webcam.flash_notify', "configClosed", true);
      }
    }

    private function activityHandler(event:ActivityEvent):void {
      debug("activityHandler: " + event);
    }

    public function snap(
      url:String, new_quality:int, shutter:Boolean, new_stealth:Boolean = false
    ):void {
      // take snapshot from camera, and upload if URL was provided
      if (new_quality) {
        set_quality(new_quality);
      }
      stealth = new_stealth;

      if (shutter) {
        channel = snd.play();
        setTimeout(snap2, 10, url);
      }
      else {
        snap2(url);
      }
    }

    public function snap2(url:String):void {
      // take snapshot, convert to jpeg, submit to server
      capture_data.draw(video, null, null, null, null, false);

      if (!stealth) {
        var matrix:Matrix = new Matrix(-1, 0, 0, 1, capture_data.width, 0);
        if (resize_needed) {
          matrix.scale(
            video_width / capture_data.width,
            video_height / capture_data.height);
        }
        display_data.draw(capture_data, matrix, null, null, null, true);

        addChild(display_bmp);
        removeChild(video);
      }

      // if URL was provided, upload now
      if (url) {
        upload(url);
      }
    }

    public function upload(url:String):void {
      if (capture_data) {
        var encoder:JPGEncoder = new JPGEncoder(jpeg_quality);
        var ba:ByteArray;

        if (!resize_needed) {
          if (server_flip) {
            ba = encoder.encode(display_data);
          }
          else {
            ba = encoder.encode(capture_data);
          }
        }
        else {
          var matrix:Matrix = new Matrix();

          if (server_flip) {
            matrix.scale(-1, 1);
            matrix.translate(server_width, 0);
          }
          if (resize_needed) {
            matrix.scale(
              server_width / capture_data.width,
              server_height / capture_data.height);
          }

          var server_data:BitmapData;
          server_data = new BitmapData(server_width, server_height);
          server_data.draw(capture_data, matrix, null, null, null, true);

          ba = encoder.encode(server_data);
        }

        var head:URLRequestHeader = new URLRequestHeader("Accept","text/*");
        var req:URLRequest = new URLRequest(url);
        req.requestHeaders.push(head);

        req.data = ba;
        req.method = URLRequestMethod.POST;
        req.contentType = "image/jpeg";

        var loader:URLLoader = new URLLoader();
        loader.addEventListener(Event.COMPLETE, onLoaded);
        loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, httpStatusHandler);
        loader.addEventListener(IOErrorEvent.IO_ERROR, ioErrorHandler);

        http_status = 0

        debug("Sending post to: " + url);

        try {
          loader.load(req);
        }
        catch (error:Error) {
          debug("Unable to load requested document.");
          ExternalInterface.call(
            'webcam.flash_notify', "error", "Unable to post data: " + error);
        }
      }
      else {
        ExternalInterface.call(
          'webcam.flash_notify', "error",
          "Nothing to upload, must capture an image first.");
      }
    }

    private function httpStatusHandler(event:HTTPStatusEvent):void {
      http_status = event.status;
    }

    public function onLoaded(event:Event):void {
      // image upload complete
      var msg:String = "unknown";
      if (event && event.target && event.target.data) {
        msg = event.target.data;
      }
      // don't include http status since it's always 200
      ExternalInterface.call('webcam.flash_notify', "success", msg);
    }

    private function ioErrorHandler(event:IOErrorEvent):void {
      ExternalInterface.call(
        'webcam.flash_notify', "uploadError", http_status);
    }

    private function statusHandler(event:StatusEvent):void {
      var msg:String = "unknown";
      if (event && event.code) {
        msg = event.code;
      }
      ExternalInterface.call('webcam.flash_notify', "security", msg);
    }

    public function reset():void {
      if (contains(display_bmp)) {
        removeChild(display_bmp);

        addChild(video);
      }
    }

    private function debug(msg:String):void {
      trace(msg);
      ExternalInterface.call('webcam.flash_notify', "debug", msg);
    }
  }
}
