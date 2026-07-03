
namespace {

BallDyn makeAdder(int64_t n);

BallDyn makeAdder(int64_t n__p) {
    auto n = std::make_shared<BallDyn>(BallDyn(n__p));
    auto& input = *n;
    return [&, n](BallDyn x) mutable {
        return ((*n) + x);
    };
    return BallDyn();
}

} // namespace

int main() {
    auto add5 = BallDyn(makeAdder(static_cast<int64_t>(5)));
    std::cout << ball_to_string(ball_to_string(add5(static_cast<int64_t>(3)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(add5(static_cast<int64_t>(10)))) << std::endl;
    return 0;
}
