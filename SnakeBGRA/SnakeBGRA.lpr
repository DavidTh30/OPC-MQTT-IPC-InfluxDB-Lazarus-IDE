program SnakeBGRA;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, usnakebgra, mqttcodec, umqttclient, snakeproto, snakeclient;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Snake Arena (BGRABitmap)';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.


