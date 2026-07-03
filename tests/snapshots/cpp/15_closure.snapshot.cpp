
namespace {

BallDyn adder(int64_t delta);

BallDyn adder(int64_t delta__p) {
    auto delta = std::make_shared<BallDyn>(BallDyn(delta__p));
    auto& input = *delta;
    return [&, delta](BallDyn x) mutable {
        return (x + (*delta));
    };
    return BallDyn();
}

} // namespace

int main() {
    auto add5 = BallDyn(adder(static_cast<int64_t>(5)));
    auto add10 = BallDyn(adder(static_cast<int64_t>(10)));
    std::cout << ball_to_string(ball_to_string(add5(static_cast<int64_t>(3)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(add10(static_cast<int64_t>(3)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(add5(add10(static_cast<int64_t>(1))))) << std::endl;
    return 0;
}
