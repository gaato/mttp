///|
pub async fn run(
  background_group : @async-core.TaskGroup[Unit],
) -> Result[Unit, Unit] {
  ignore(background_group)
  @app.start()
  Ok(())
}
