program MqttStream;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, ustreammain, mqttcodec, mqttbroker, uwaves, ustreams;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'MQTT Stream Server';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
