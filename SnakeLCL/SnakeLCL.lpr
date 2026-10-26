program SnakeLCL;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, usnakelcl, mqttcodec, umqttclient, snakeproto, snakeclient;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Snake Arena (LCL)';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
