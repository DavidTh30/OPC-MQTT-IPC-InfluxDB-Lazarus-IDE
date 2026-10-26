program MqttClient;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, uclientmain, mqttcodec, umqttclient;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'MQTT Client';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
