module SomeModule
import TestSubgraphTrackingPath
using Test

@test TestSubgraphTrackingPath.addfive(1) == 6

end
