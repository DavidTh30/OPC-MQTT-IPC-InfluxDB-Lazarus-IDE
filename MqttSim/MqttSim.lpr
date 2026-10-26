program MqttSim;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, umqttmain, mqttcodec, mqttbroker, usimtopics, uplcsim;

{$R *.res}

begin
  MaskFPUExceptions;
  RequireDerivedFormResource := True;
  Application.Title := 'MQTT Simulator';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
