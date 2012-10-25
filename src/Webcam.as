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
  import flash.text.TextField;
  import flash.text.TextFormat;
  import flash.text.TextFieldAutoSize;
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
    private var intro:TextField;

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

      var format:TextFormat = new TextFormat()
      format.size = 22;
      format.font = "_sans";

      intro = new TextField();
      intro.text = "Waiting for camera...";
      intro.setTextFormat(format);
      intro.width = intro.textWidth + 20;
      intro.height = intro.textHeight + 20;
      intro.x = Math.floor((stage.stageWidth - intro.textWidth) / 2);
      intro.y = Math.floor((stage.stageHeight - intro.textHeight) / 2);
      addChild(intro);

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

      if (!camera) {
        debug("No camera was detected.");
        ExternalInterface.call(
          'webcam.flash_notify', "error", "No camera was detected.");
        return;
      }

      camera.addEventListener(StatusEvent.STATUS, statusHandler);

      // Select between two most popular camera modes.
      // I don't know of a way to detect camera's native aspect ratio,
      // but most cameras should support an aspect ratio of 3:2.
      if (Math.max(video_width, server_width) <= 320 &&
          Math.max(video_height, server_height) <= 240)
      {
        camera.setMode(320, 240, 30);
      }
      else {
        camera.setMode(640, 480, 30);
      }

      // do not detect motion (may help reduce CPU usage)
      camera.setMotionLevel(100);

      video = new Video(camera.width, camera.height);
      video.attachCamera(camera);

      var matrix:Matrix = get_matrix(video_width, video_height, true);
      video.scaleX = matrix.a;
      video.scaleY = matrix.d;
      video.x = matrix.tx;
      video.y = matrix.ty;

      addChild(video);

      ExternalInterface.addCallback('_snap', snap);
      ExternalInterface.addCallback('_configure', configure);
      ExternalInterface.addCallback('_upload', upload);
      ExternalInterface.addCallback('_reset', reset);

      if (flashvars.shutter_enabled == 1) {
        snd = new Sound();
        snd.load(new URLRequest(flashvars.shutter_url));
      }

      jpeg_quality = 90;

      capture_data = new BitmapData(camera.width, camera.height);
      display_data = new BitmapData(video_width, video_height);
      display_bmp = new Bitmap(display_data);

      ExternalInterface.call(
        'webcam.flash_notify', 'flashLoadComplete', !camera.muted);
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
        var matrix:Matrix;
        matrix = get_matrix(video_width, video_height, true);
        display_data.draw(capture_data, matrix, null, null, null, true);

        addChild(display_bmp);
      }

      // if URL was provided, upload now
      if (url) {
        upload(url);
      }
    }

    public function upload(url:String, csrf_token:String = null):void {
      if (capture_data) {
        var matrix:Matrix;
        matrix = get_matrix(server_width, server_height, server_flip);

        var server_data:BitmapData;
        server_data = new BitmapData(server_width, server_height);
        server_data.draw(capture_data, matrix, null, null, null, true);

        var encoder:JPGEncoder = new JPGEncoder(jpeg_quality);

        var ba:ByteArray;
        ba = encoder.encode(server_data);

        var req:URLRequest = new URLRequest(url);
        req.requestHeaders.push(new URLRequestHeader("Accept", "text/*"));

        if (csrf_token && csrf_token.length) {
          req.requestHeaders.push(
            new URLRequestHeader("X-CSRF-Token", csrf_token));
        }

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
      ExternalInterface.call('webcam.flash_notify', "security", event.code);
    }

    public function reset():void {
      if (contains(display_bmp)) {
        removeChild(display_bmp);
      }
    }

    private function get_matrix(to_x:Number, to_y:Number, flip:Boolean):Matrix {
      var flip_scale:Number = flip ? -1 : 1;
      var matrix:Matrix;
      matrix = new Matrix(flip_scale, 0, 0, 1, 0, 0);

      var scale:Number = Math.max(to_x / camera.width, to_y / camera.height);
      matrix.scale(scale, scale);

      var x_offset:Number = flip ? to_x : 0;
      var y_offset:Number;
      var scaled_width:Number = scale * camera.width;
      var scaled_height:Number = scale * camera.height;

      if (scaled_width > to_x) {
        x_offset += -flip_scale * Math.floor((scaled_width - to_x) / 2);
      }
      else if (scaled_height > to_y) {
        y_offset = -Math.floor((scaled_height - to_y) / 2);
      }

      matrix.translate(x_offset, y_offset);

      return matrix;
    }

    private function debug(msg:String):void {
      trace(msg);
      ExternalInterface.call('webcam.flash_notify', "debug", msg);
    }
  }
}
